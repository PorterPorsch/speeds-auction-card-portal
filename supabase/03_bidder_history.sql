-- =====================================================================
-- Speed's Auction Card Portal — bidder history
-- Every change to a bidder is written here automatically by the database.
-- Safe to run again.
-- =====================================================================

create table if not exists public.bidder_history (
  id            bigint generated always as identity primary key,
  bidder_id     uuid not null,          -- same id while active, archived, or restored
  bidder_number text,
  event         text not null,          -- added, issued, renewed, printed, photo, edited, archived, restored
  details       text not null default '',
  happened_at   timestamptz not null default now(),
  by_user       uuid,
  by_name       text
);
create index if not exists bidder_history_bidder_idx on public.bidder_history (bidder_id, happened_at desc);
create index if not exists bidder_history_number_idx on public.bidder_history (bidder_number);

alter table public.bidder_history enable row level security;
drop policy if exists "history read" on public.bidder_history;
create policy "history read" on public.bidder_history for select to authenticated using (public.can('staff'));
grant select on public.bidder_history to authenticated;
grant select, insert, update, delete on public.bidder_history to service_role;

-- ---------- the logger ----------
create or replace function public.log_bidder_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  who   uuid := auth.uid();
  wname text := (select coalesce(nullif(full_name, ''), email) from public.staff where user_id = auth.uid());
  chg   text[] := '{}';
  b     public.bidders;
begin
  if tg_op = 'DELETE' then
    b := old;
    insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
    values (b.id, b.bidder_number, 'archived',
            coalesce(nullif(current_setting('app.archive_reason', true), ''), 'Moved to archive'), who, wname);
    return old;
  end if;

  b := new;

  if tg_op = 'INSERT' then
    if current_setting('app.restoring', true) = 'on' then
      insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
      values (b.id, b.bidder_number, 'restored', 'Brought back from the archive', who, wname);
      return new;
    end if;
    insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
    values (b.id, b.bidder_number, 'added',
      case b.source
        when 'cloudbadging' then 'Loaded from CloudBadging'
        when 'tops'         then 'Added from the full Tops bidder list'
        when 'manual'       then 'Added by hand'
        else 'New bidder from the weekly Tops list' end
      || coalesce(' — ' || nullif(b.notes, ''), ''), who, wname);
    if b.date_issued is not null then
      insert into public.bidder_history (bidder_id, bidder_number, event, details, happened_at, by_user, by_name)
      values (b.id, b.bidder_number, 'issued',
              'Card issued ' || b.date_issued || coalesce(', expires ' || b.expires, '')
              || case when b.source = 'cloudbadging' then ' (CloudBadging)' else '' end,
              case when b.source = 'cloudbadging' then (b.date_issued::text || ' 12:00 America/Los_Angeles')::timestamptz else now() end,
              who, wname);
    end if;
    return new;
  end if;

  -- UPDATE
  if new.date_issued is distinct from old.date_issued and new.date_issued is not null then
    insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
    values (b.id, b.bidder_number, case when old.date_issued is null then 'issued' else 'renewed' end,
            'Card issued ' || new.date_issued || coalesce(', expires ' || new.expires, '')
            || coalesce(' (previous: ' || old.date_issued || coalesce(' to ' || old.expires, '') || ')', '')
            || coalesce(' — ' || nullif(new.notes, ''), ''), who, wname);
  end if;
  if new.last_printed is distinct from old.last_printed and new.last_printed is not null then
    insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
    values (b.id, b.bidder_number, 'printed', 'Card printed (print #' || new.print_count || ')', who, wname);
  end if;
  if new.photo_path is distinct from old.photo_path then
    insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
    values (b.id, b.bidder_number, 'photo',
            case when new.photo_path is null then 'Photo removed'
                 when old.photo_path is null then 'Photo added'
                 else 'Photo changed' end, who, wname);
  end if;
  if new.bidder_number is distinct from old.bidder_number then
    chg := chg || ('Number ' || old.bidder_number || ' → ' || new.bidder_number);
  end if;
  if (new.first_name, new.middle_initial, new.last_name) is distinct from (old.first_name, old.middle_initial, old.last_name) then
    chg := chg || ('Name ' || trim(old.first_name || ' ' || old.last_name) || ' → ' || trim(new.first_name || ' ' || new.last_name));
  end if;
  if new.expires is distinct from old.expires and new.date_issued is not distinct from old.date_issued then
    chg := chg || ('Expires ' || coalesce(old.expires::text, 'blank') || ' → ' || coalesce(new.expires::text, 'blank'));
  end if;
  if new.notes is distinct from old.notes and new.date_issued is not distinct from old.date_issued then
    chg := chg || ('Notes: ' || coalesce(nullif(new.notes, ''), '(cleared)'));
  end if;
  if array_length(chg, 1) > 0 then
    insert into public.bidder_history (bidder_id, bidder_number, event, details, by_user, by_name)
    values (b.id, b.bidder_number, 'edited', array_to_string(chg, ' · '), who, wname);
  end if;
  return new;
end $$;

drop trigger if exists bidders_history on public.bidders;
create trigger bidders_history after insert or update or delete on public.bidders
for each row execute function public.log_bidder_change();

-- ---------- archive / restore now pass their reason to the logger ----------
create or replace function public.archive_bidder(p_id uuid, p_reason text)
returns void
language plpgsql security invoker as $$
begin
  perform set_config('app.archive_reason', coalesce(p_reason, ''), true);
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

create or replace function public.restore_bidder(p_id uuid)
returns void
language plpgsql security invoker as $$
begin
  perform set_config('app.restoring', 'on', true);
  insert into public.bidders
    (id, bidder_number, first_name, middle_initial, last_name, customer, notes, tops_key,
     photo_path, photo_date, date_issued, expires, print_count, last_printed, source,
     created_at, updated_at)
  select id, bidder_number, first_name, middle_initial, last_name, customer, notes, tops_key,
     photo_path, photo_date, date_issued, expires, print_count,
     last_printed, coalesce(source, 'manual'), coalesce(created_at, now()), now()
  from public.bidders_archive where id = p_id;
  perform set_config('app.restoring', 'off', true);
  delete from public.bidders_archive where id = p_id;
end $$;

-- ---------- backfill: the 29 bidders already in the portal ----------
insert into public.bidder_history (bidder_id, bidder_number, event, details, happened_at, by_name)
select b.id, b.bidder_number, 'added',
       case b.source when 'manual' then 'Added by hand' else 'New bidder from the weekly Tops list' end || coalesce(' — ' || nullif(b.notes, ''), ''),
       b.created_at, null
from public.bidders b
where not exists (select 1 from public.bidder_history h where h.bidder_id = b.id);

insert into public.bidder_history (bidder_id, bidder_number, event, details, happened_at, by_name)
select b.id, b.bidder_number, 'issued', 'Card issued ' || b.date_issued || coalesce(', expires ' || b.expires, ''), b.created_at + interval '1 second', null
from public.bidders b
where b.date_issued is not null and not exists (select 1 from public.bidder_history h where h.bidder_id = b.id and h.event = 'issued');

insert into public.bidder_history (bidder_id, bidder_number, event, details, happened_at, by_name)
select b.id, b.bidder_number, 'photo', 'Photo added', b.photo_date, null
from public.bidders b
where b.photo_path is not null and not exists (select 1 from public.bidder_history h where h.bidder_id = b.id and h.event = 'photo');

select event, count(*) from public.bidder_history group by event order by 1;
