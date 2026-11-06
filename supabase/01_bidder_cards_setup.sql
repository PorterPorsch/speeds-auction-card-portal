-- =====================================================================
-- Speed's Auction Card Portal — Supabase setup
-- Run once in Supabase: SQL Editor > New query > paste > Run
-- =====================================================================

-- ---------- Active bidders ----------
create table if not exists public.bidders (
  id             uuid primary key default gen_random_uuid(),
  bidder_number  text not null,
  first_name     text not null default '',
  middle_initial text not null default '',
  last_name      text not null default '',
  customer       text not null default '',
  notes          text not null default '',
  tops_key       text,                          -- BDRlBidderKey from the Tops export
  photo_path     text,                          -- path in storage bucket bidder-photos
  photo_date     timestamptz,
  date_issued    date,                          -- blank for CloudBadging records that were never printed
  expires        date,
  print_count    integer not null default 0,
  last_printed   timestamptz,
  source         text not null default 'weekly', -- weekly | cloudbadging | manual
  cb_photo_file  text,                          -- photo file name from the CloudBadging export (e.g. 1612-photo.jpg)
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint bidders_number_unique unique (bidder_number)
);
create index if not exists bidders_tops_key_idx on public.bidders (tops_key);
create index if not exists bidders_last_name_idx on public.bidders (lower(last_name));

-- ---------- Archive (old bidders whose number was reused, or archived by hand) ----------
create table if not exists public.bidders_archive (
  id               uuid primary key,            -- same id the record had while active
  bidder_number    text not null,
  first_name       text not null default '',
  middle_initial   text not null default '',
  last_name        text not null default '',
  customer         text not null default '',
  notes            text not null default '',
  tops_key         text,
  photo_path       text,
  photo_date       timestamptz,
  date_issued      date,
  expires          date,
  print_count      integer not null default 0,
  last_printed     timestamptz,
  source           text,
  created_at       timestamptz,
  updated_at       timestamptz,
  archived_at      timestamptz not null default now(),
  archived_reason  text not null default '',    -- e.g. 'Number reused by Jane Doe'
  archived_by      uuid
);
create index if not exists bidders_archive_number_idx on public.bidders_archive (bidder_number);
create index if not exists bidders_archive_last_name_idx on public.bidders_archive (lower(last_name));

-- ---------- Settings (one row) ----------
create table if not exists public.bidder_card_settings (
  id              integer primary key default 1 check (id = 1),
  term_months     integer not null default 12,       -- card good for this many months
  barcode_format  text not null default 'CODE39',    -- CODE39 or CODE128
  logo_path       text,                              -- optional uploaded logo in bidder-photos/branding/
  updated_at      timestamptz not null default now()
);
insert into public.bidder_card_settings (id) values (1) on conflict (id) do nothing;

-- ---------- updated_at trigger ----------
create or replace function public.bidders_touch() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists bidders_touch on public.bidders;
create trigger bidders_touch before update on public.bidders
for each row execute function public.bidders_touch();

-- ---------- Move a bidder to the archive (one step, can't half-happen) ----------
create or replace function public.archive_bidder(p_id uuid, p_reason text)
returns void
language plpgsql security invoker as $$
begin
  insert into public.bidders_archive
    (id, bidder_number, first_name, middle_initial, last_name, customer, notes, tops_key,
     photo_path, photo_date, date_issued, expires, print_count, last_printed, source,
     created_at, updated_at, archived_reason, archived_by)
  select id, bidder_number, first_name, middle_initial, last_name, customer, notes, tops_key,
     photo_path, photo_date, date_issued, expires, print_count, last_printed, source,
     created_at, updated_at, coalesce(p_reason, ''), auth.uid()
  from public.bidders where id = p_id
  on conflict (id) do update set archived_at = now(), archived_reason = excluded.archived_reason;

  delete from public.bidders where id = p_id;
end $$;

-- ---------- Bring a bidder back from the archive ----------
create or replace function public.restore_bidder(p_id uuid)
returns void
language plpgsql security invoker as $$
begin
  insert into public.bidders
    (id, bidder_number, first_name, middle_initial, last_name, customer, notes, tops_key,
     photo_path, photo_date, date_issued, expires, print_count, last_printed, source,
     created_at, updated_at)
  select id, bidder_number, first_name, middle_initial, last_name, customer, notes, tops_key,
     photo_path, photo_date, coalesce(date_issued, current_date), expires, print_count,
     last_printed, coalesce(source, 'manual'), coalesce(created_at, now()), now()
  from public.bidders_archive where id = p_id;

  delete from public.bidders_archive where id = p_id;
end $$;

-- ---------- Row level security: any signed-in staff member ----------
alter table public.bidders              enable row level security;
alter table public.bidders_archive      enable row level security;
alter table public.bidder_card_settings enable row level security;

drop policy if exists "staff all" on public.bidders;
create policy "staff all" on public.bidders for all to authenticated using (true) with check (true);
drop policy if exists "staff all" on public.bidders_archive;
create policy "staff all" on public.bidders_archive for all to authenticated using (true) with check (true);
drop policy if exists "staff all" on public.bidder_card_settings;
create policy "staff all" on public.bidder_card_settings for all to authenticated using (true) with check (true);

-- ---------- Grants (required for new tables) ----------
grant select, insert, update, delete on public.bidders              to authenticated, service_role;
grant select, insert, update, delete on public.bidders_archive      to authenticated, service_role;
grant select, insert, update, delete on public.bidder_card_settings to authenticated, service_role;
grant execute on function public.archive_bidder(uuid, text) to authenticated, service_role;
grant execute on function public.restore_bidder(uuid)       to authenticated, service_role;

-- ---------- Photo storage (private bucket) ----------
insert into storage.buckets (id, name, public)
values ('bidder-photos', 'bidder-photos', false)
on conflict (id) do nothing;

drop policy if exists "bidder photos read"   on storage.objects;
drop policy if exists "bidder photos write"  on storage.objects;
drop policy if exists "bidder photos update" on storage.objects;
drop policy if exists "bidder photos delete" on storage.objects;
create policy "bidder photos read"   on storage.objects for select to authenticated using (bucket_id = 'bidder-photos');
create policy "bidder photos write"  on storage.objects for insert to authenticated with check (bucket_id = 'bidder-photos');
create policy "bidder photos update" on storage.objects for update to authenticated using (bucket_id = 'bidder-photos');
create policy "bidder photos delete" on storage.objects for delete to authenticated using (bucket_id = 'bidder-photos');

-- ---------- Photos taken at the auction for people who aren't in Tops ----------
create table if not exists public.unmatched_photos (
  id                  uuid primary key default gen_random_uuid(),
  photo_path          text not null,              -- in bucket bidder-photos
  bidder_number_seen  text not null default '',   -- number written on the card in the photo, if readable
  note                text not null default '',   -- name or anything staff knows
  batch_date          date not null default current_date,
  created_at          timestamptz not null default now(),
  resolved_at         timestamptz,
  resolved_bidder_id  uuid,
  resolution          text not null default ''    -- 'matched to #1234' / 'dismissed'
);
create index if not exists unmatched_photos_open_idx on public.unmatched_photos (batch_date) where resolved_at is null;

alter table public.unmatched_photos enable row level security;
drop policy if exists "staff all" on public.unmatched_photos;
create policy "staff all" on public.unmatched_photos for all to authenticated using (true) with check (true);
grant select, insert, update, delete on public.unmatched_photos to authenticated, service_role;
