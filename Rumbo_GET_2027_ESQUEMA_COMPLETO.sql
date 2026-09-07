-- ============================================================
-- RUMBO GET 2027 · ESQUEMA SUPABASE V1
-- Login real + datos reales + RLS + ciclo 90 días
-- ============================================================

begin;

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ---------- TIPOS ----------
do $$ begin
  create type public.cycle_status as enum ('planned','active','closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.prospect_stage as enum (
    'new','contacted','conversation','invited','presented','followup',
    'client','distributor','leader_emerging','no_for_now','inactive'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.priority_level as enum ('low','medium','high','critical');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.followup_status as enum ('pending','completed','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.activity_type as enum ('contact','followup','presentation','note');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.presentation_type as enum ('business','wellness','both');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.presentation_mode as enum ('in_person','video_call','event','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.presentation_status as enum ('scheduled','completed','cancelled','no_show');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.presentation_result as enum (
    'very_interested','interested','thinking','client','distributor',
    'another_presentation','no_for_now','other'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.conversion_type as enum ('client','distributor','leader_emerging');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.goal_type as enum (
    'daily_contacts','weekly_presentations','daily_power_hours',
    'monthly_pv','monthly_income','cycle_clients','cycle_distributors','cycle_leaders'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.income_source as enum ('direct_sales','wholesale','royalties','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.pv_source as enum ('personal','client','distributor','organization','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.review_type as enum ('weekly','monthly','cycle_90d');
exception when duplicate_object then null; end $$;

-- ---------- FUNCIONES GENERALES ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function public.normalize_phone_text(v text)
returns text
language sql
immutable
as $$
  select case
    when v is null or trim(v) = '' then null
    else regexp_replace(v, '[^0-9]', '', 'g')
  end
$$;

-- ---------- PERFIL ----------
create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  timezone text not null default 'America/Lima',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

-- ---------- CICLOS ----------
create table if not exists public.cycles(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  objective text,
  start_date date not null,
  end_date date not null,
  status public.cycle_status not null default 'planned',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(end_date = start_date + 89)
);

create unique index if not exists one_active_cycle_per_user
on public.cycles(user_id)
where status='active';

drop trigger if exists trg_cycles_updated_at on public.cycles;
create trigger trg_cycles_updated_at
before update on public.cycles
for each row execute function public.set_updated_at();

-- ---------- PROSPECTOS ----------
create table if not exists public.prospects(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null check(length(trim(full_name)) between 2 and 150),
  phone_raw text,
  phone_normalized text,
  category text not null default 'U' check(category in ('A','B','U')),
  origin text not null default 'Lista personal',
  stage public.prospect_stage not null default 'new',
  first_contact_at timestamptz,
  client_since timestamptz,
  distributor_since timestamptz,
  leader_since timestamptz,
  priority public.priority_level not null default 'medium',
  notes text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists prospects_user_stage_idx
on public.prospects(user_id, stage)
where archived_at is null;

create index if not exists prospects_user_phone_idx
on public.prospects(user_id, phone_normalized)
where phone_normalized is not null and archived_at is null;

create or replace function public.normalize_prospect_phone()
returns trigger
language plpgsql
as $$
begin
  new.phone_normalized := public.normalize_phone_text(new.phone_raw);

  if new.phone_normalized is not null
     and (length(new.phone_normalized) < 7 or length(new.phone_normalized) > 15) then
    raise exception 'Teléfono inválido';
  end if;

  return new;
end $$;

drop trigger if exists trg_normalize_prospect_phone on public.prospects;
create trigger trg_normalize_prospect_phone
before insert or update of phone_raw on public.prospects
for each row execute function public.normalize_prospect_phone();

drop trigger if exists trg_prospects_updated_at on public.prospects;
create trigger trg_prospects_updated_at
before update on public.prospects
for each row execute function public.set_updated_at();

-- ---------- REGLAS DE DÍAS / META DIARIA ----------
create table if not exists public.workday_rules(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  weekday smallint not null check(weekday between 1 and 7), -- 1=lunes ... 7=domingo
  is_active boolean not null default true,
  contact_target integer check(contact_target in (5,7,8,9,10)),
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to >= effective_from),
  check((is_active and contact_target is not null) or (not is_active))
);

-- ---------- METAS VERSIONADAS ----------
create table if not exists public.goal_rules(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  cycle_id uuid references public.cycles(id) on delete cascade,
  goal_type public.goal_type not null,
  target_value numeric(14,2) not null check(target_value >= 0),
  effective_from date not null,
  effective_to date,
  notes text,
  created_at timestamptz not null default now(),
  check(effective_to is null or effective_to >= effective_from)
);

create index if not exists goal_rules_user_type_idx
on public.goal_rules(user_id, goal_type, effective_from desc);

-- ---------- ACTIVIDADES ----------
create table if not exists public.activities(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete restrict,
  cycle_id uuid references public.cycles(id) on delete set null,
  activity_type public.activity_type not null,
  occurred_at timestamptz not null default now(),
  had_conversation boolean not null default false,
  invitation_made boolean not null default false,
  is_first_contact boolean not null default false,
  no_response boolean not null default false,
  notes text,
  voided_at timestamptz,
  created_at timestamptz not null default now(),
  check(not(no_response and had_conversation)),
  check(not is_first_contact or had_conversation)
);

create unique index if not exists one_first_contact_per_prospect
on public.activities(prospect_id)
where is_first_contact=true and voided_at is null;

create index if not exists activities_user_date_idx
on public.activities(user_id, occurred_at desc)
where voided_at is null;

create or replace function public.mark_first_contact()
returns trigger
language plpgsql
as $$
declare
  existing_first timestamptz;
  p_user uuid;
begin
  select first_contact_at, user_id
    into existing_first, p_user
  from public.prospects
  where id = new.prospect_id
  for update;

  if p_user is distinct from new.user_id then
    raise exception 'El prospecto no pertenece al usuario';
  end if;

  if new.had_conversation = false then
    new.is_first_contact := false;
    return new;
  end if;

  if existing_first is null then
    new.is_first_contact := true;
    update public.prospects
      set first_contact_at = new.occurred_at,
          stage = case when stage='new' then 'conversation' else stage end,
          updated_at = now()
      where id = new.prospect_id;
  else
    new.is_first_contact := false;
  end if;

  return new;
end $$;

drop trigger if exists trg_mark_first_contact on public.activities;
create trigger trg_mark_first_contact
before insert on public.activities
for each row execute function public.mark_first_contact();

-- ---------- SEGUIMIENTOS ----------
create table if not exists public.followups(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete restrict,
  cycle_id uuid references public.cycles(id) on delete set null,
  source_activity_id uuid references public.activities(id) on delete set null,
  next_step text not null check(length(trim(next_step)) between 2 and 500),
  scheduled_for timestamptz,
  priority public.priority_level not null default 'medium',
  status public.followup_status not null default 'pending',
  completed_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists followups_user_status_date_idx
on public.followups(user_id, status, scheduled_for);

drop trigger if exists trg_followups_updated_at on public.followups;
create trigger trg_followups_updated_at
before update on public.followups
for each row execute function public.set_updated_at();

-- ---------- PRESENTACIONES ----------
create table if not exists public.presentations(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete restrict,
  cycle_id uuid references public.cycles(id) on delete set null,
  presentation_type public.presentation_type not null,
  presentation_mode public.presentation_mode not null default 'in_person',
  scheduled_for timestamptz,
  completed_at timestamptz,
  duration_minutes integer check(duration_minutes is null or duration_minutes > 0),
  status public.presentation_status not null default 'scheduled',
  result public.presentation_result,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(
    (status='completed' and completed_at is not null)
    or status <> 'completed'
  )
);

create index if not exists presentations_user_status_date_idx
on public.presentations(user_id, status, scheduled_for);

drop trigger if exists trg_presentations_updated_at on public.presentations;
create trigger trg_presentations_updated_at
before update on public.presentations
for each row execute function public.set_updated_at();

create or replace function public.sync_completed_presentation()
returns trigger
language plpgsql
as $$
begin
  if new.status='completed'
     and (old.status is distinct from 'completed') then

    insert into public.activities(
      user_id, prospect_id, cycle_id, activity_type, occurred_at,
      had_conversation, invitation_made, notes
    )
    values(
      new.user_id, new.prospect_id, new.cycle_id, 'presentation',
      coalesce(new.completed_at, now()), false, false,
      'Presentación completada'
    );

    update public.prospects
      set stage = case
        when stage in ('client','distributor','leader_emerging') then stage
        else 'presented'
      end,
      updated_at=now()
    where id=new.prospect_id;
  end if;

  return new;
end $$;

drop trigger if exists trg_sync_completed_presentation on public.presentations;
create trigger trg_sync_completed_presentation
after update on public.presentations
for each row execute function public.sync_completed_presentation();

-- ---------- CONVERSIONES ----------
create table if not exists public.conversions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete restrict,
  cycle_id uuid references public.cycles(id) on delete set null,
  conversion_type public.conversion_type not null,
  converted_at timestamptz not null default now(),
  evidence text,
  reversed_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index if not exists one_active_conversion_type_per_prospect
on public.conversions(prospect_id, conversion_type)
where reversed_at is null;

create index if not exists conversions_user_date_idx
on public.conversions(user_id, converted_at desc);

create or replace function public.apply_conversion()
returns trigger
language plpgsql
as $$
begin
  if new.conversion_type='client' then
    update public.prospects
      set stage='client',
          client_since=coalesce(client_since,new.converted_at),
          updated_at=now()
    where id=new.prospect_id;
  elsif new.conversion_type='distributor' then
    update public.prospects
      set stage='distributor',
          distributor_since=coalesce(distributor_since,new.converted_at),
          updated_at=now()
    where id=new.prospect_id;
  elsif new.conversion_type='leader_emerging' then
    update public.prospects
      set stage='leader_emerging',
          leader_since=coalesce(leader_since,new.converted_at),
          updated_at=now()
    where id=new.prospect_id;
  end if;

  return new;
end $$;

drop trigger if exists trg_apply_conversion on public.conversions;
create trigger trg_apply_conversion
after insert on public.conversions
for each row execute function public.apply_conversion();

-- ---------- ROLES ACTIVOS / REACTIVACIONES ----------
create table if not exists public.role_periods(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete restrict,
  role_type public.conversion_type not null,
  started_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  check(ended_at is null or ended_at >= started_at)
);

create unique index if not exists one_active_role_per_prospect
on public.role_periods(prospect_id, role_type)
where ended_at is null;

create or replace function public.create_role_period_from_conversion()
returns trigger
language plpgsql
as $$
begin
  insert into public.role_periods(
    user_id, prospect_id, role_type, started_at
  )
  values(
    new.user_id, new.prospect_id, new.conversion_type, new.converted_at
  )
  on conflict do nothing;

  return new;
end $$;

drop trigger if exists trg_create_role_period_from_conversion on public.conversions;
create trigger trg_create_role_period_from_conversion
after insert on public.conversions
for each row execute function public.create_role_period_from_conversion();

-- ---------- PV E INGRESOS ----------
create table if not exists public.business_entries(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  cycle_id uuid references public.cycles(id) on delete set null,
  entry_date date not null default current_date,
  pv numeric(12,2) not null default 0 check(pv >= 0),
  pv_source public.pv_source,
  income_amount numeric(12,2) not null default 0 check(income_amount >= 0),
  income_source public.income_source,
  notes text,
  created_at timestamptz not null default now(),
  check(pv > 0 or income_amount > 0)
);

create index if not exists business_entries_user_date_idx
on public.business_entries(user_id, entry_date desc);

-- ---------- HORAS BLOQUE DE PODER ----------
create table if not exists public.power_time_entries(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  cycle_id uuid references public.cycles(id) on delete set null,
  entry_date date not null default current_date,
  hours numeric(5,2) not null check(hours > 0 and hours <= 24),
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists power_time_user_date_idx
on public.power_time_entries(user_id, entry_date desc);

-- ---------- REVISIONES ----------
create table if not exists public.reviews(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  cycle_id uuid references public.cycles(id) on delete set null,
  review_type public.review_type not null,
  period_start date not null,
  period_end date not null,
  what_worked text,
  what_to_improve text,
  observations text,
  closed_at timestamptz,
  snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(period_end >= period_start)
);

drop trigger if exists trg_reviews_updated_at on public.reviews;
create trigger trg_reviews_updated_at
before update on public.reviews
for each row execute function public.set_updated_at();

create table if not exists public.review_priorities(
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references public.reviews(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  position smallint not null check(position between 1 and 3),
  priority_text text not null,
  created_at timestamptz not null default now(),
  unique(review_id, position)
);

-- ---------- CONFIGURACIÓN ----------
create table if not exists public.app_settings(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  project_name text not null default 'Rumbo GET 2027',
  default_timezone text not null default 'America/Lima',
  next_step_required boolean not null default true,
  reminders_today boolean not null default true,
  reminders_overdue boolean not null default true,
  reminders_presentations boolean not null default true,
  reminders_reviews boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_app_settings_updated_at on public.app_settings;
create trigger trg_app_settings_updated_at
before update on public.app_settings
for each row execute function public.set_updated_at();

-- ---------- ALTA AUTOMÁTICA DE USUARIO ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.profiles(id, full_name)
  values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''))
  on conflict(id) do nothing;

  insert into public.app_settings(user_id)
  values(new.id)
  on conflict(user_id) do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Backfill de usuarios que ya existan en Auth
insert into public.profiles(id, full_name)
select id, coalesce(raw_user_meta_data->>'full_name','')
from auth.users
on conflict(id) do nothing;

insert into public.app_settings(user_id)
select id from auth.users
on conflict(user_id) do nothing;

-- ---------- VISTAS ----------
create or replace view public.v_daily_kpis as
select
  user_id,
  (occurred_at at time zone 'America/Lima')::date as activity_date,
  count(*) filter(where is_first_contact and voided_at is null) as new_contacts,
  count(*) filter(where had_conversation and voided_at is null) as conversations,
  count(*) filter(where invitation_made and voided_at is null) as invitations,
  count(*) filter(where activity_type='presentation' and voided_at is null) as presentations,
  count(*) filter(where activity_type='followup' and voided_at is null) as followups
from public.activities
group by user_id, (occurred_at at time zone 'America/Lima')::date;

create or replace view public.v_daily_business_results as
select
  user_id,
  entry_date,
  sum(pv) as pv,
  sum(income_amount) as income
from public.business_entries
group by user_id, entry_date;

create or replace view public.v_daily_power_hours as
select
  user_id,
  entry_date,
  sum(hours) as power_hours
from public.power_time_entries
group by user_id, entry_date;

create or replace view public.v_active_roles as
select
  user_id,
  prospect_id,
  role_type,
  started_at
from public.role_periods
where ended_at is null;

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.cycles enable row level security;
alter table public.prospects enable row level security;
alter table public.workday_rules enable row level security;
alter table public.goal_rules enable row level security;
alter table public.activities enable row level security;
alter table public.followups enable row level security;
alter table public.presentations enable row level security;
alter table public.conversions enable row level security;
alter table public.role_periods enable row level security;
alter table public.business_entries enable row level security;
alter table public.power_time_entries enable row level security;
alter table public.reviews enable row level security;
alter table public.review_priorities enable row level security;
alter table public.app_settings enable row level security;

-- perfiles
drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles for select
using(id=auth.uid());
create policy "profiles_update_own"
on public.profiles for update
using(id=auth.uid()) with check(id=auth.uid());

-- ciclos
drop policy if exists "cycles_select_own" on public.cycles;
drop policy if exists "cycles_insert_own" on public.cycles;
drop policy if exists "cycles_update_own" on public.cycles;
create policy "cycles_select_own" on public.cycles for select using(user_id=auth.uid());
create policy "cycles_insert_own" on public.cycles for insert with check(user_id=auth.uid());
create policy "cycles_update_own" on public.cycles for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- prospectos
drop policy if exists "prospects_select_own" on public.prospects;
drop policy if exists "prospects_insert_own" on public.prospects;
drop policy if exists "prospects_update_own" on public.prospects;
create policy "prospects_select_own" on public.prospects for select using(user_id=auth.uid());
create policy "prospects_insert_own" on public.prospects for insert with check(user_id=auth.uid());
create policy "prospects_update_own" on public.prospects for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- reglas de días
drop policy if exists "workdays_select_own" on public.workday_rules;
drop policy if exists "workdays_insert_own" on public.workday_rules;
drop policy if exists "workdays_update_own" on public.workday_rules;
create policy "workdays_select_own" on public.workday_rules for select using(user_id=auth.uid());
create policy "workdays_insert_own" on public.workday_rules for insert with check(user_id=auth.uid());
create policy "workdays_update_own" on public.workday_rules for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- metas
drop policy if exists "goals_select_own" on public.goal_rules;
drop policy if exists "goals_insert_own" on public.goal_rules;
drop policy if exists "goals_update_own" on public.goal_rules;
create policy "goals_select_own" on public.goal_rules for select using(user_id=auth.uid());
create policy "goals_insert_own" on public.goal_rules for insert with check(user_id=auth.uid());
create policy "goals_update_own" on public.goal_rules for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- actividades
drop policy if exists "activities_select_own" on public.activities;
drop policy if exists "activities_insert_own" on public.activities;
drop policy if exists "activities_update_own" on public.activities;
create policy "activities_select_own" on public.activities for select using(user_id=auth.uid());
create policy "activities_insert_own" on public.activities for insert with check(user_id=auth.uid());
create policy "activities_update_own" on public.activities for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- seguimientos
drop policy if exists "followups_select_own" on public.followups;
drop policy if exists "followups_insert_own" on public.followups;
drop policy if exists "followups_update_own" on public.followups;
create policy "followups_select_own" on public.followups for select using(user_id=auth.uid());
create policy "followups_insert_own" on public.followups for insert with check(user_id=auth.uid());
create policy "followups_update_own" on public.followups for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- presentaciones
drop policy if exists "presentations_select_own" on public.presentations;
drop policy if exists "presentations_insert_own" on public.presentations;
drop policy if exists "presentations_update_own" on public.presentations;
create policy "presentations_select_own" on public.presentations for select using(user_id=auth.uid());
create policy "presentations_insert_own" on public.presentations for insert with check(user_id=auth.uid());
create policy "presentations_update_own" on public.presentations for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- conversiones
drop policy if exists "conversions_select_own" on public.conversions;
drop policy if exists "conversions_insert_own" on public.conversions;
drop policy if exists "conversions_update_own" on public.conversions;
create policy "conversions_select_own" on public.conversions for select using(user_id=auth.uid());
create policy "conversions_insert_own" on public.conversions for insert with check(user_id=auth.uid());
create policy "conversions_update_own" on public.conversions for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- roles
drop policy if exists "roles_select_own" on public.role_periods;
drop policy if exists "roles_insert_own" on public.role_periods;
drop policy if exists "roles_update_own" on public.role_periods;
create policy "roles_select_own" on public.role_periods for select using(user_id=auth.uid());
create policy "roles_insert_own" on public.role_periods for insert with check(user_id=auth.uid());
create policy "roles_update_own" on public.role_periods for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- negocio
drop policy if exists "business_select_own" on public.business_entries;
drop policy if exists "business_insert_own" on public.business_entries;
drop policy if exists "business_update_own" on public.business_entries;
create policy "business_select_own" on public.business_entries for select using(user_id=auth.uid());
create policy "business_insert_own" on public.business_entries for insert with check(user_id=auth.uid());
create policy "business_update_own" on public.business_entries for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- horas poder
drop policy if exists "power_select_own" on public.power_time_entries;
drop policy if exists "power_insert_own" on public.power_time_entries;
drop policy if exists "power_update_own" on public.power_time_entries;
create policy "power_select_own" on public.power_time_entries for select using(user_id=auth.uid());
create policy "power_insert_own" on public.power_time_entries for insert with check(user_id=auth.uid());
create policy "power_update_own" on public.power_time_entries for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- revisiones
drop policy if exists "reviews_select_own" on public.reviews;
drop policy if exists "reviews_insert_own" on public.reviews;
drop policy if exists "reviews_update_own" on public.reviews;
create policy "reviews_select_own" on public.reviews for select using(user_id=auth.uid());
create policy "reviews_insert_own" on public.reviews for insert with check(user_id=auth.uid());
create policy "reviews_update_own" on public.reviews for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- prioridades revisión
drop policy if exists "priorities_select_own" on public.review_priorities;
drop policy if exists "priorities_insert_own" on public.review_priorities;
drop policy if exists "priorities_update_own" on public.review_priorities;
create policy "priorities_select_own" on public.review_priorities for select using(user_id=auth.uid());
create policy "priorities_insert_own" on public.review_priorities for insert with check(user_id=auth.uid());
create policy "priorities_update_own" on public.review_priorities for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- configuración
drop policy if exists "settings_select_own" on public.app_settings;
drop policy if exists "settings_insert_own" on public.app_settings;
drop policy if exists "settings_update_own" on public.app_settings;
create policy "settings_select_own" on public.app_settings for select using(user_id=auth.uid());
create policy "settings_insert_own" on public.app_settings for insert with check(user_id=auth.uid());
create policy "settings_update_own" on public.app_settings for update using(user_id=auth.uid()) with check(user_id=auth.uid());

-- ---------- PERMISOS ----------
grant usage on schema public to authenticated;
grant select, insert, update on all tables in schema public to authenticated;
grant select on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ---------- LIMPIEZA DE LA TABLA DE PRUEBA ----------
drop table if exists public.prueba_rumbo_get;

commit;
