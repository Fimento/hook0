-- ============================================================
-- Migration: 20210720134539_init.up.sql
-- ============================================================

create extension if not exists pgcrypto with schema public;

set search_path to public; -- public is necessary so that sqlx can find its _sqlx_migrations table
set plpgsql.extra_warnings to 'all';






create schema event;

create table event.organization
(
    organization__id uuid not null default public.gen_random_uuid(),
    name text not null,
    created_at timestamptz not null default statement_timestamp(),
    constraint organization_pkey primary key (organization__id),
    constraint organization_name_chk check (length(name) > 1)
);

create table event.application
(
    application__id  uuid not null default public.gen_random_uuid(),
    organization__id uuid not null ,
    name text not null,
    created_at timestamptz not null default statement_timestamp(),
    constraint application_pkey primary key (application__id),
    constraint application_name_chk check (length(name) > 1)
);

alter table event.application add constraint application_organization__id_fkey
foreign key (organization__id)
references event.organization (organization__id)
match simple
on delete cascade
on update cascade;

create table event.service
(
    service__name text not null,
    application__id uuid not null,
    comment text,
    constraint service_pkey primary key (service__name, application__id)
);

alter table event.service add constraint service_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

create table event.resource_type
(
    resource_type__name text not null,
    application__id uuid not null,
    service__name text not null,
    constraint resource_type_pkey primary key (application__id, service__name, resource_type__name)
);

alter table event.resource_type add constraint resource_type_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

alter table event.resource_type add constraint resource_type_application__id_service__name_fkey
foreign key (application__id, service__name)
references event.service (application__id, service__name)
match simple
on delete restrict
on update restrict;

create table event.verb
(
    verb__name text not null,
    application__id uuid not null,
    constraint verb_pkey primary key (verb__name, application__id)
);

alter table event.verb add constraint verb_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

create table event.event_type
(
    application__id uuid not null,
    service__name text not null,
    resource_type__name text not null,
    verb__name text not null,
    created_at timestamptz not null default statement_timestamp(),
    is_enabled boolean not null default true,
    event_type__name text not null generated always as ((((service__name || '.'::text) || resource_type__name) || '.'::text) || verb__name) stored,
    constraint event_type_pkey primary key (event_type__name)
);

alter table event.event_type add constraint event_type_application__id_service__name_fkey
foreign key (application__id, service__name)
references event.service (application__id, service__name)
match simple
on delete restrict
on update restrict;

alter table event.event_type add constraint event_type_application__id_verb__name_fkey
foreign key (application__id, verb__name)
references event.verb (application__id, verb__name)
match simple
on delete restrict
on update restrict;

alter table event.event_type add constraint event_type_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

alter table event.event_type add constraint event_type_service__name_application__id_resource_type__name
foreign key (service__name, application__id, resource_type__name)
references event.resource_type (service__name, application__id, resource_type__name) match simple
on delete restrict on update restrict;

create table event.application_secret
(
    token uuid not null default public.gen_random_uuid(),
    application__id uuid not null,
    created_at timestamptz not null default statement_timestamp(),
    deleted_at timestamptz,
    name text,
    constraint application_secret_pkey primary key (token)
);

alter table event.application_secret add constraint application_secret_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

create table event.payload_content_type
(
    payload_content_type__name text not null,
    description text not null,
    created_at timestamptz not null default statement_timestamp(),
    constraint payload_content_type_pkey primary key (payload_content_type__name)
);

create table event.event
(
    event__id uuid not null default public.gen_random_uuid() primary key,
    application__id uuid not null,
    event_type__name text not null,
    payload bytea not null,
    payload_content_type__name text not null,
    ip inet not null,
    metadata jsonb,
    occurred_at timestamptz not null,
    received_at timestamptz not null default statement_timestamp(),
    dispatched_at timestamptz,
    application_secret__token  uuid not null,
    labels jsonb not null default jsonb_build_object(),
    constraint event_metadata_is_object check ((metadata is null) or (jsonb_typeof(metadata) = 'object')),
    constraint event_labels_is_object check (jsonb_typeof(labels) = 'object')
);

alter table event.event add constraint event_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

alter table event.event add constraint event_application_secret__token_fkey
foreign key (application_secret__token)
references event.application_secret (token)
match simple
on delete restrict
on update restrict;

alter table event.event add constraint event_payload_content_type__name_fkey
foreign key (payload_content_type__name)
references event.payload_content_type (payload_content_type__name)
match simple
on delete restrict
on update restrict;

alter table event.event add constraint event_event_type__name_fkey
foreign key (event_type__name)
references event.event_type (event_type__name)
match simple
on delete restrict
on update restrict;

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    key text;
    value text;
    subscription_id uuid;
begin
    for key, value in select * from jsonb_each_text(new.labels) limit 50
        loop
            for subscription_id in
                select subscription__id
                from webhook.subscription
                where is_enabled
                  and label_key = key
                  and label_value = value
                loop
                    raise notice '[event %] matching subscription: %', event__id, subscription_id;
                    insert into webhook.request_attempt (event__id, subscription__id)
                    values (new.event__id, subscription_id);
                end loop;
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;





create schema webhook;

create table webhook.subscription
(
    subscription__id uuid not null default public.gen_random_uuid(),
    application__id uuid not null,
    is_enabled boolean not null default true,
    description text,
    secret uuid not null default public.gen_random_uuid(),
    metadata jsonb not null default jsonb_build_object(),
    label_key text not null,
    label_value text not null,
    target__id uuid not null,
    created_at timestamptz not null default statement_timestamp(),
    constraint subscription_pkey primary key (subscription__id),
    constraint subscription_target__id_key unique (target__id),
    constraint subscription_metadata_is_object check ((metadata is null) or (jsonb_typeof(metadata) = 'object'))
);

alter table webhook.subscription add constraint subscription_application__id_fkey
foreign key (application__id)
references event.application (application__id)
match simple
on delete cascade
on update cascade;

create table webhook.subscription__event_type
(
    subscription__id uuid not null,
    event_type__name text not null,
    constraint subscription__event_type_pkey primary key (subscription__id, event_type__name)
);

alter table webhook.subscription__event_type add constraint subscription__event_type_subscription__id_fkey
foreign key (subscription__id)
references webhook.subscription (subscription__id)
match simple
on delete cascade
on update cascade;

alter table webhook.subscription__event_type add constraint subscription__event_type_event_type__name_fkey
foreign key (event_type__name)
references event.event_type (event_type__name)
match simple
on delete cascade
on update cascade;

create table webhook.response_error
(
    response_error__name text not null,
    constraint response_error_pkey primary key (response_error__name)
);

create table webhook.response
(
    response__id uuid not null default public.gen_random_uuid(),
    response_error__name text,
    http_code smallint,
    headers jsonb,
    body text,
    elapsed_time_ms integer,
    constraint response_pkey primary key (response__id),
    constraint response_headers_is_object check ((headers is null) or (jsonb_typeof(headers) = 'object'))
);

alter table webhook.response add constraint response_response_error__name_fkey
foreign key (response_error__name)
references webhook.response_error (response_error__name)
match simple
on delete restrict
on update cascade;

create table webhook.request_attempt
(
    request_attempt__id uuid not null default public.gen_random_uuid(),
    event__id uuid not null,
    subscription__id uuid not null,
    created_at timestamptz not null default statement_timestamp(),
    picked_at timestamptz,
    worker_id text,
    worker_version text,
    failed_at timestamptz,
    succeeded_at timestamptz,
    delay_until timestamptz,
    response__id uuid,
    retry_count smallint not null default 0,
    constraint request_attempt_pkey primary key (request_attempt__id),
    constraint request_attempt_response__id_key unique (response__id)
);

alter table webhook.request_attempt add constraint request_attempt_subscription__id_fkey
foreign key (subscription__id)
references webhook.subscription (subscription__id)
match simple
on delete restrict
on update restrict;

alter table webhook.request_attempt add constraint request_attempt_event__id_fkey
foreign key (event__id)
references event.event (event__id)
match simple
on delete cascade
on update cascade;

alter table webhook.request_attempt add constraint request_attempt_response__id_fkey
foreign key (response__id)
references webhook.response (response__id)
match simple
on delete set null
on update cascade;

create table webhook.target
(
    target__id uuid not null default public.gen_random_uuid(),
    constraint target_pkey primary key (target__id)
);

alter table webhook.target add constraint target_target__id_fkey
foreign key (target__id)
references webhook.subscription (target__id)
match simple
on delete cascade
on update cascade;

create table webhook.target_http
(
    target__id uuid not null default public.gen_random_uuid(),
    method text not null,
    url text not null,
    headers jsonb not null default jsonb_build_object(),
    constraint target_http_headers_is_object check (jsonb_typeof(headers) = 'object')
)
inherits (webhook.target);

alter table webhook.target_http  add constraint target_http_target__id_fkey
foreign key (target__id)
references webhook.subscription (target__id)
match simple
on delete cascade
on update cascade;


-- ============================================================
-- Migration: 20211114234847_add_event_dispatch_trigger.up.sql
-- ============================================================

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    key text;
    value text;
    subscription_id uuid;
begin
    for key, value in select * from jsonb_each_text(new.labels) limit 50
        loop
            for subscription_id in
                select subscription__id
                from webhook.subscription
                where is_enabled
                  and label_key = key
                  and label_value = value
                loop
                    raise notice '[event %] matching subscription: %', new.event__id, subscription_id;
                    insert into webhook.request_attempt (event__id, subscription__id)
                    values (new.event__id, subscription_id);
                end loop;
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;

create trigger event_dispatch
    after insert
    on event.event
    for each row
    execute function event.dispatch();


-- ============================================================
-- Migration: 20220224095346_add_organization_created_by.up.sql
-- ============================================================

alter table event.organization add column created_by uuid not null default '00000000-0000-0000-0000-000000000000';


-- ============================================================
-- Migration: 20220527140321_remove_payload_content_type.up.sql
-- ============================================================

alter table event.event drop constraint event_payload_content_type__name_fkey;
drop table event.payload_content_type;
alter table event.event rename column payload_content_type__name to payload_content_type;


-- ============================================================
-- Migration: 20221013134343_add_subscriptions_soft_delete.up.sql
-- ============================================================

alter table webhook.subscription add column deleted_at timestamptz default null;

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    key text;
    value text;
    subscription_id uuid;
begin
    for key, value in select * from jsonb_each_text(new.labels) limit 50
        loop
            for subscription_id in
                select subscription__id
                from webhook.subscription
                where is_enabled
                  and deleted_at is null
                  and label_key = key
                  and label_value = value
                loop
                    raise notice '[event %] matching subscription: %', new.event__id, subscription_id;
                    insert into webhook.request_attempt (event__id, subscription__id)
                    values (new.event__id, subscription_id);
                end loop;
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;


-- ============================================================
-- Migration: 20221027144137_fix_event_type_primary_key.up.sql
-- ============================================================

alter table event.event_type rename constraint event_type_pkey to event_type_pkeyold;
create unique index event_type_pkey on event.event_type (application__id, event_type__name);
alter table event.event_type drop constraint event_type_pkeyold cascade;
alter table event.event_type add primary key using index event_type_pkey;

alter table event.event add constraint event_event_type__name_fkey
foreign key (application__id, event_type__name)
references event.event_type (application__id, event_type__name)
match simple
on delete restrict
on update restrict;

alter table webhook.subscription__event_type add column application__id uuid;
update webhook.subscription__event_type set application__id = event.event_type.application__id from event.event_type where webhook.subscription__event_type.event_type__name = event.event_type.event_type__name;
alter table webhook.subscription__event_type alter column application__id set not null;
alter table webhook.subscription__event_type add constraint subscription__event_type_event_type__name_fkey
foreign key (application__id, event_type__name)
references event.event_type (application__id, event_type__name)
match simple
on delete cascade
on update cascade;


-- ============================================================
-- Migration: 20230519134651_add_quotas.up.sql
-- ============================================================

create schema iam;
alter table event.organization set schema iam;

create schema pricing;
create table pricing.plan
(
    plan__id uuid not null primary key default public.gen_random_uuid(),
    name text not null unique,
    label text not null,
    created_at timestamptz not null default statement_timestamp(),
    members_per_organization_limit integer,
    applications_per_organization_limit integer,
    events_per_day_limit integer,
    days_of_events_retention_limit integer
);
create table pricing.price
(
    price__id uuid not null primary key default public.gen_random_uuid(),
    plan__id uuid not null references pricing.plan (plan__id),
    amount numeric(7, 2) not null,
    time_basis text not null,
    created_at timestamptz not null default statement_timestamp(),
    description text
);

alter table iam.organization add column price__id uuid default null references pricing.price (price__id);

alter table event.application add column events_per_day_limit integer default null;
alter table event.application add column days_of_events_retention_limit integer default null;


-- ============================================================
-- Migration: 20230525215504_add_workers.up.sql
-- ============================================================

create schema infrastructure;

create table infrastructure.worker (
    worker__id uuid not null primary key default public.gen_random_uuid(),
    name text not null unique,
    description text,
    created_at timestamptz not null default statement_timestamp(),
    public boolean not null default false
);

create table iam.organization__worker (
    organization__id uuid not null references iam.organization (organization__id) on update cascade on delete cascade,
    worker__id uuid not null references infrastructure.worker (worker__id) on update cascade on delete cascade,
    constraint worker__organization_pkey primary key (organization__id, worker__id)
);
comment on table iam.organization__worker is 'when a worker is associated to an organization it means that the organization can use this worker';

create table webhook.subscription__worker (
    subscription__id uuid not null references webhook.subscription (subscription__id) on update cascade on delete cascade,
    worker__id uuid not null references infrastructure.worker (worker__id) on update cascade on delete cascade,
    constraint subscription__worker_pkey primary key (subscription__id, worker__id)
);

alter table webhook.request_attempt rename column worker_id to worker_name;


-- ============================================================
-- Migration: 20231029163157_add_default_workers.up.sql
-- ============================================================

alter table iam.organization__worker add column "default" boolean default false;


-- ============================================================
-- Migration: 20231110091203_fix_event_dispatch.up.sql
-- ============================================================

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    key text;
    value text;
    subscription_id uuid;
begin
    for key, value in select * from jsonb_each_text(new.labels) limit 50
        loop
            for subscription_id in
                select subscription__id
                from webhook.subscription
                where is_enabled
                  and application__id = new.application__id
                  and deleted_at is null
                  and label_key = key
                  and label_value = value
                loop
                    raise notice '[event %] matching subscription: %', new.event__id, subscription_id;
                    insert into webhook.request_attempt (event__id, subscription__id)
                    values (new.event__id, subscription_id);
                end loop;
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;


-- ============================================================
-- Migration: 20231110112401_add_events_per_day_materialized_view.up.sql
-- ============================================================

create materialized view event.events_per_day as (
    select application__id, received_at::date as date, count(event__id)::integer as amount
    from event.event
    group by date, application__id
    order by date desc, amount desc
);

create unique index on event.events_per_day (application__id, date);


-- ============================================================
-- Migration: 20240327010233_add_index_in_request_attempt_table.up.sql
-- ============================================================

create index if not exists request_attempt_event__id_idx on webhook.request_attempt (event__id);


-- ============================================================
-- Migration: 20240327011331_add_all_time_events_per_day_table.up.sql
-- ============================================================

create table event.all_time_events_per_day (
    application__id uuid not null,
    date date not null,
    amount integer not null,
    primary key (application__id, date)
);


-- ============================================================
-- Migration: 20240415112558_fix_event_dispatch.up.sql
-- ============================================================

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    key text;
    value text;
    subscription_id uuid;
begin
    for key, value in select * from jsonb_each_text(new.labels) limit 50
        loop
            for subscription_id in
                select s.subscription__id
                from webhook.subscription as s
                inner join webhook.subscription__event_type as set on set.subscription__id = s.subscription__id
                where s.is_enabled
                  and s.application__id = new.application__id
                  and s.deleted_at is null
                  and set.event_type__name = new.event_type__name
                  and s.label_key = key
                  and s.label_value = value
                loop
                    raise notice '[event %] matching subscription: %', new.event__id, subscription_id;
                    insert into webhook.request_attempt (event__id, subscription__id)
                    values (new.event__id, subscription_id);
                end loop;
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;


-- ============================================================
-- Migration: 20240425073314_iam_v2.up.sql
-- ============================================================

create table iam.user (
    user__id uuid not null primary key default public.gen_random_uuid(),
    email text not null unique,
    password text not null,
    first_name text not null,
    last_name text not null,
    created_at timestamptz not null default statement_timestamp(),
    email_verified_at timestamptz,
    last_login timestamptz
);

create table iam.user__organization (
    user__id uuid not null,
    organization__id uuid not null,
    role text not null,
    created_at timestamptz not null default statement_timestamp(),
    primary key (user__id, organization__id),
    constraint user__organization_user__id_fk foreign key (user__id) references iam.user (user__id) on delete cascade on update cascade,
    constraint user__organization_organization__id_fk foreign key (organization__id) references iam.organization (organization__id) on delete cascade on update cascade,
    constraint user__organization_role_chk check (role in ('editor', 'viewer'))
);

create table iam.token (
    token__id uuid not null primary key default public.gen_random_uuid(),
    created_at timestamptz not null default statement_timestamp(),
    type text not null,
    revocation_id bytea not null,
    expired_at timestamptz,
    organization__id uuid,
    name text,
    biscuit text,
    user__id uuid ,
    session_id uuid,
    constraint token_type_chk check (type in ('service_access', 'user_access', 'refresh')),
    constraint token_expired_at_chk check (type = 'service_access' or expired_at is not null),
    constraint token_organization__id_fk foreign key (organization__id) references iam.organization (organization__id) on delete cascade on update cascade,
    constraint token_organization__id_chk check (type != 'service_access' or organization__id is not null),
    constraint token_name_chk check (type != 'service_access' or name is not null),
    constraint token_biscuit_chk check (type != 'service_access' or biscuit is not null),
    constraint token_user__id_fk foreign key (user__id) references iam.user (user__id) on delete cascade on update cascade,
    constraint token_user__id_chk check (type not in ('user_access', 'refresh') or user__id is not null),
    constraint token_session_id_chk check (type not in ('user_access', 'refresh') or session_id is not null)
);

create index token_revocation_id_idx on iam.token (revocation_id);
create index token_organization__id_idx on iam.token (organization__id);
create index token_user__id_idx on iam.token (user__id);

alter table event.event alter column application_secret__token drop not null;


-- ============================================================
-- Migration: 20240522104648_allow_redispatching_events.up.sql
-- ============================================================

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    key text;
    value text;
    subscription_id uuid;
begin
    if new.dispatched_at is not null then
        return new;
    end if;

    for key, value in select * from jsonb_each_text(new.labels) limit 50
        loop
            for subscription_id in
                select s.subscription__id
                from webhook.subscription as s
                         inner join webhook.subscription__event_type as set on set.subscription__id = s.subscription__id
                where s.is_enabled
                  and s.application__id = new.application__id
                  and s.deleted_at is null
                  and set.event_type__name = new.event_type__name
                  and s.label_key = key
                  and s.label_value = value
                loop
                    raise notice '[event %] matching subscription: %', new.event__id, subscription_id;
                    insert into webhook.request_attempt (event__id, subscription__id)
                    values (new.event__id, subscription_id);
                end loop;
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;

drop trigger event_dispatch on event.event;

create trigger event_dispatch
    after insert or update
    on event.event
    for each row
execute function event.dispatch();


-- ============================================================
-- Migration: 20240529214726_add_index_in_event_table.up.sql
-- ============================================================

create index if not exists event_application__id_idx on event.event (application__id);


-- ============================================================
-- Migration: 20240614093632_make_email_case_insensitive.up.sql
-- ============================================================

create collation if not exists case_insensitive (provider = icu, locale = 'und-u-ks-level2', deterministic = false);

alter table iam.user alter column email set data type text collate case_insensitive;


-- ============================================================
-- Migration: 20240712100624_add_index_in_request_attempt_table.up.sql
-- ============================================================

create index if not exists request_attempt_subscription__id_idx on webhook.request_attempt (subscription__id);


-- ============================================================
-- Migration: 20240830092103_add_event_types_deactivation_date.up.sql
-- ============================================================

alter table event.event_type drop column is_enabled;
alter table event.event_type add column deactivated_at timestamptz default null;
create index if not exists event_type_application__id_idx on event.event_type (application__id);


-- ============================================================
-- Migration: 20250109085445_add_limit_subscription_per_application.up.sql
-- ============================================================

alter table pricing.plan add column subscriptions_per_application_limit integer default null;
alter table pricing.plan add column event_types_per_application_limit integer default null;


-- ============================================================
-- Migration: 20250113090629_add_index_in_subscription_table.up.sql
-- ============================================================

create index if not exists subscription_application__id_idx on webhook.subscription (application__id);


-- ============================================================
-- Migration: 20250122131824_add_application_soft_deleting.up.sql
-- ============================================================

alter table event.application add column deleted_at timestamptz default null;


-- ============================================================
-- Migration: 20250123100742_add_quota_notification_table.up.sql
-- ============================================================

CREATE TABLE pricing.quota_notifications (
    quota_notification__id uuid not null default public.gen_random_uuid(),
    application__id uuid,
    organization__id uuid,
    name text not null,
    type text check (type in ('Reached', 'Warning')) not null,
    executed_at timestamptz not null default now(),
    constraint quota_notification_at_least_one_id_chk check (
        (application__id is not null and organization__id is null) or
        (organization__id is not null and application__id is null)
    ),
    constraint quota_notification_name_chk check (length(name) > 1),
    constraint quota_notification_application__id_fkey foreign key (application__id)
        references event.application (application__id)
        on delete cascade,
    constraint quota_notification_organization__id_fkey foreign key (organization__id)
        references iam.organization (organization__id)
        on delete cascade
);

CREATE INDEX idx_quota_notifications_app_id ON pricing.quota_notifications (application__id);
CREATE INDEX idx_quota_notifications_org_id ON pricing.quota_notifications (organization__id);


-- ============================================================
-- Migration: 20250307113853_add_indexes_to_improve_worker_performances.up.sql
-- ============================================================

create index if not exists target_http_target__id_idx on webhook.target_http (target__id);
create index if not exists application_deleted_at_idx on event.application (deleted_at);


-- ============================================================
-- Migration: 20250806151141_allow_multiple_labels_in_subscriptions.up.sql
-- ============================================================

alter table webhook.subscription add column labels jsonb;
alter table webhook.subscription add constraint labels_chk check (jsonb_typeof(labels) = 'object' and labels != '{}'::jsonb);
update webhook.subscription set labels = jsonb_build_object(label_key, label_value);
alter table webhook.subscription alter column labels set not null;
alter table webhook.subscription drop column label_key;
alter table webhook.subscription drop column label_value;

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
declare
    subscription_id uuid;
begin
    if new.dispatched_at is not null then
        return new;
    end if;

    for subscription_id in
        select s.subscription__id
        from webhook.subscription as s
                  inner join webhook.subscription__event_type as set on set.subscription__id = s.subscription__id
        where s.is_enabled
          and s.application__id = new.application__id
          and s.deleted_at is null
          and set.event_type__name = new.event_type__name
          and new.labels @> s.labels
        loop
            raise notice '[event %] matching subscription: %', new.event__id, subscription_id;
            insert into webhook.request_attempt (event__id, subscription__id)
            values (new.event__id, subscription_id);
        end loop;
    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;

drop trigger event_dispatch on event.event;

create trigger event_dispatch
    after insert or update
    on event.event
    for each row
execute function event.dispatch();


-- ============================================================
-- Migration: 20250904134003_add_index_in_request_attempt_table.up.sql
-- ============================================================

create index if not exists request_attempt_waiting_idx on webhook.request_attempt (created_at) where (succeeded_at is null and failed_at is null);


-- ============================================================
-- Migration: 20251011130707_add_index_to_improve_removing_dangling_responses.up.sql
-- ============================================================

create index if not exists request_attempt_no_response_idx on webhook.request_attempt (response__id) where response__id is null;


-- ============================================================
-- Migration: 20251011135852_add_index_to_request_attempt_fetching.up.sql
-- ============================================================

create index if not exists request_attempt_created_at_idx on webhook.request_attempt using brin (created_at, subscription__id, event__id) with (autosummarize = on, pages_per_range = 50);


-- ============================================================
-- Migration: 20251011141722_add_worker_queue_type.up.sql
-- ============================================================

alter table infrastructure.worker add column queue_type text not null default 'pg';

alter table infrastructure.worker add constraint queue_type_chk check (queue_type in ('pg', 'pulsar'));


-- ============================================================
-- Migration: 20251012225037_remove_useless_index.up.sql
-- ============================================================

drop index webhook.request_attempt_no_response_idx;


-- ============================================================
-- Migration: 20251013154626_make_event_payload_optional.up.sql
-- ============================================================

alter table event.event alter column payload drop not null;


-- ============================================================
-- Migration: 20251105164547_convert_response_body_to_binary.up.sql
-- ============================================================

alter table webhook.response alter column body type bytea using (convert_to(body, 'UTF8'));


-- ============================================================
-- Migration: 20251106195654_add_various_indexes.up.sql
-- ============================================================

create index if not exists event_received_at_idx on event.event using brin (received_at) with (autosummarize = on);
create index if not exists application_organization__id_idx on event.application (organization__id);


-- ============================================================
-- Migration: 20251116203141_change_type_of_request_attempt_created_at_index.up.sql
-- ============================================================

create index if not exists request_attempt_created_at_btree_idx on webhook.request_attempt (created_at);
alter index webhook.request_attempt_created_at_idx rename to request_attempt_created_at_brin_idx;
alter index webhook.request_attempt_created_at_btree_idx rename to request_attempt_created_at_idx;
drop index webhook.request_attempt_created_at_brin_idx;


-- ============================================================
-- Migration: 20251130182548_reduce_scope_of_events_per_day_materialized_view.up.sql
-- ============================================================

drop materialized view event.events_per_day;
create materialized view event.events_per_day as (
    select application__id, received_at::date as date, count(event__id)::integer as amount
    from event.event
    where received_at >= (current_date - interval '3 days')
    group by date, application__id
    order by date desc, amount desc
);

create unique index on event.events_per_day (application__id, date);


-- ============================================================
-- Migration: 20251204171458_add_application_id_to_request_attempt_table.up.sql
-- ============================================================

alter table webhook.request_attempt add column application__id uuid references event.application (application__id) on update cascade on delete cascade;

create or replace function event.dispatch()
    returns trigger
    language plpgsql
as
$$
begin
    if new.dispatched_at is not null then
        return new;
    end if;

    insert into webhook.request_attempt (event__id, subscription__id, application__id)
    select new.event__id, s.subscription__id, s.application__id
    from webhook.subscription as s
    inner join webhook.subscription__event_type as set on set.subscription__id = s.subscription__id
    where s.is_enabled
      and s.application__id = new.application__id
      and s.deleted_at is null
      and set.event_type__name = new.event_type__name
      and new.labels @> s.labels;

    update event.event set dispatched_at = statement_timestamp() where event__id = new.event__id;
    return new;
end;
$$;

drop trigger event_dispatch on event.event;

create trigger event_dispatch
    after insert or update
    on event.event
    for each row
execute function event.dispatch();


-- ============================================================
-- Migration: 20251204190214_finalize_request_attempt_application_id.up.sql
-- ============================================================

create index if not exists request_attempt_application__id_idx on webhook.request_attempt (application__id);
alter table webhook.request_attempt alter column application__id set not null;


