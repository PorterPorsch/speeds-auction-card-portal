-- =====================================================================
-- Speed's Auction Card Portal — staff logins & permissions
-- Run after bidder_cards_setup.sql. Safe to run again.
-- =====================================================================

create table if not exists public.staff (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  full_name    text not null default '',
  active       boolean not null default true,
  perm_import  boolean not null default false,  -- Weekly Import
  perm_photos  boolean not null default false,  -- Photos + Not in Tops
  perm_print   boolean not null default false,  -- Print Queue / print cards
  perm_edit    boolean not null default false,  -- edit records, add bidders
  perm_archive boolean not null default false,  -- archive, restore, replace a reused number
  perm_admin   boolean not null default false,  -- Settings, Users, everything
  created_at   timestamptz not null default now()
);

-- does the signed-in person have this permission?  (admin = everything)
create or replace function public.can(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select active and (perm_admin or case p
      when 'import'  then perm_import
      when 'photos'  then perm_photos
      when 'print'   then perm_print
      when 'edit'    then perm_edit
      when 'archive' then perm_archive
      when 'staff'   then true          -- any active staff member
      else false end)
    from public.staff where user_id = auth.uid()), false);
$$;
grant execute on function public.can(text) to authenticated, service_role;

alter table public.staff enable row level security;
drop policy if exists "staff read"  on public.staff;
drop policy if exists "staff admin" on public.staff;
create policy "staff read"  on public.staff for select to authenticated using (user_id = auth.uid() or public.can('admin'));
create policy "staff admin" on public.staff for all    to authenticated using (public.can('admin')) with check (public.can('admin'));
grant select, insert, update, delete on public.staff to authenticated, service_role;

-- ---------- replace the open "any signed-in user" policies ----------
drop policy if exists "staff all" on public.bidders;
drop policy if exists "staff all" on public.bidders_archive;
drop policy if exists "staff all" on public.bidder_card_settings;
drop policy if exists "staff all" on public.unmatched_photos;

drop policy if exists "bidders read"   on public.bidders;
drop policy if exists "bidders insert" on public.bidders;
drop policy if exists "bidders update" on public.bidders;
drop policy if exists "bidders delete" on public.bidders;
create policy "bidders read"   on public.bidders for select to authenticated using (public.can('staff'));
create policy "bidders insert" on public.bidders for insert to authenticated with check (public.can('import') or public.can('edit') or public.can('archive'));
create policy "bidders update" on public.bidders for update to authenticated
  using (public.can('import') or public.can('edit') or public.can('photos') or public.can('print'))
  with check (public.can('import') or public.can('edit') or public.can('photos') or public.can('print'));
create policy "bidders delete" on public.bidders for delete to authenticated using (public.can('archive'));

drop policy if exists "archive read"  on public.bidders_archive;
drop policy if exists "archive write" on public.bidders_archive;
create policy "archive read"  on public.bidders_archive for select to authenticated using (public.can('staff'));
create policy "archive write" on public.bidders_archive for all to authenticated using (public.can('archive')) with check (public.can('archive'));

drop policy if exists "settings read"  on public.bidder_card_settings;
drop policy if exists "settings write" on public.bidder_card_settings;
create policy "settings read"  on public.bidder_card_settings for select to authenticated using (public.can('staff'));
create policy "settings write" on public.bidder_card_settings for update to authenticated using (public.can('admin')) with check (public.can('admin'));

drop policy if exists "unmatched read"  on public.unmatched_photos;
drop policy if exists "unmatched write" on public.unmatched_photos;
create policy "unmatched read"  on public.unmatched_photos for select to authenticated using (public.can('staff'));
create policy "unmatched write" on public.unmatched_photos for all to authenticated using (public.can('photos')) with check (public.can('photos'));

-- ---------- photo storage ----------
drop policy if exists "bidder photos read"   on storage.objects;
drop policy if exists "bidder photos write"  on storage.objects;
drop policy if exists "bidder photos update" on storage.objects;
drop policy if exists "bidder photos delete" on storage.objects;
create policy "bidder photos read"   on storage.objects for select to authenticated using (bucket_id = 'bidder-photos' and public.can('staff'));
create policy "bidder photos write"  on storage.objects for insert to authenticated with check (bucket_id = 'bidder-photos' and (public.can('photos') or public.can('edit')));
create policy "bidder photos update" on storage.objects for update to authenticated using (bucket_id = 'bidder-photos' and (public.can('photos') or public.can('edit')));
create policy "bidder photos delete" on storage.objects for delete to authenticated using (bucket_id = 'bidder-photos' and public.can('admin'));

-- ---------- make whoever is already signed up (Porter) an admin ----------
insert into public.staff (user_id, email, full_name, perm_admin, perm_import, perm_photos, perm_print, perm_edit, perm_archive)
select id, email, 'Mike Porter', true, true, true, true, true, true from auth.users
on conflict (user_id) do update set perm_admin = true, active = true;

select email, perm_admin from public.staff;
