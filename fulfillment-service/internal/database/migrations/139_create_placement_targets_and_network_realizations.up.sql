--
-- Copyright (c) 2026 Red Hat Inc.
--
-- Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
-- the License. You may obtain a copy of the License at
--
--   http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
-- an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
-- specific language governing permissions and limitations under the License.
--

-- Both records are private Fulfillment resources, attributed to the OSAC tenant even when
-- multiple OSAC tenants share one NICo tenant. Network realizations are independent of BMIs.

create table bare_metal_placement_targets (
  id text not null primary key,
  name text not null check (name <> ''),
  creation_timestamp timestamptz not null default now(),
  deletion_timestamp timestamptz not null default 'epoch',
  finalizers text[] not null default '{}',
  creator text not null default '',
  tenant text not null default '' check (tenant <> 'shared'),
  project ltree not null default ''::ltree,
  labels jsonb not null default '{}'::jsonb,
  annotations jsonb not null default '{}'::jsonb,
  data jsonb not null,
  version integer not null default 0
);

create table archived_bare_metal_placement_targets (
  id text not null,
  name text not null default '',
  creation_timestamp timestamptz not null,
  deletion_timestamp timestamptz not null,
  archival_timestamp timestamptz not null default now(),
  creator text not null default '',
  tenant text not null default '',
  project ltree not null default ''::ltree,
  labels jsonb not null default '{}'::jsonb,
  annotations jsonb not null default '{}'::jsonb,
  data jsonb not null,
  version integer not null default 0
);

create table active_bare_metal_placement_targets (
  id text not null primary key references bare_metal_placement_targets (id) on delete cascade
);

create unique index bare_metal_placement_targets_unique_name
  on bare_metal_placement_targets (tenant, name) where deletion_timestamp = 'epoch';
create index bare_metal_placement_targets_by_type
  on bare_metal_placement_targets (tenant, (data->'spec'->>'osac_instance_type_id'))
  where deletion_timestamp = 'epoch';
create index bare_metal_placement_targets_by_creator on bare_metal_placement_targets (creator);
-- Target removal checks every active BMI that pinned the target.
create index bare_metal_instances_by_placement_target
  on bare_metal_instances ((data->'status'->>'placement_target_id'))
  where deletion_timestamp = 'epoch' and coalesce(data->'status'->>'placement_target_id', '') <> '';
create index bare_metal_placement_targets_by_label on bare_metal_placement_targets using gin (labels);
alter table bare_metal_placement_targets add constraint bare_metal_placement_targets_tenant_fk
  foreign key (tenant) references tenants (name);
alter table bare_metal_placement_targets add constraint bare_metal_placement_targets_project_fk
  foreign key (tenant, project) references projects (tenant, name);
create trigger check_immutable_columns before update on bare_metal_placement_targets
  for each row execute function check_immutable_columns('id', 'name', 'tenant', 'project');
create trigger materialize_active_objects after insert or update of deletion_timestamp on bare_metal_placement_targets
  for each row execute function materialize_active_objects();
create trigger enqueue_change after insert or update or delete on bare_metal_placement_targets
  for each row execute function enqueue_change();

create table network_realizations (
  id text not null primary key,
  name text not null check (name <> ''),
  creation_timestamp timestamptz not null default now(),
  deletion_timestamp timestamptz not null default 'epoch',
  finalizers text[] not null default '{}',
  creator text not null default '',
  tenant text not null default '' check (tenant <> 'shared'),
  project ltree not null default ''::ltree,
  labels jsonb not null default '{}'::jsonb,
  annotations jsonb not null default '{}'::jsonb,
  data jsonb not null,
  version integer not null default 0
);

create table archived_network_realizations (
  id text not null,
  name text not null default '',
  creation_timestamp timestamptz not null,
  deletion_timestamp timestamptz not null,
  archival_timestamp timestamptz not null default now(),
  creator text not null default '',
  tenant text not null default '',
  project ltree not null default ''::ltree,
  labels jsonb not null default '{}'::jsonb,
  annotations jsonb not null default '{}'::jsonb,
  data jsonb not null,
  version integer not null default 0
);

create table active_network_realizations (
  id text not null primary key references network_realizations (id) on delete cascade
);

-- Prefix intents hold an active parent VPC intent. The foreign key prevents a VPC
-- from being soft-deleted while a Prefix still references it, including races
-- between a child create and parent delete.
alter table network_realizations add column parent_realization_id text
  generated always as (nullif(data->'spec'->>'parent_realization_id', '')) stored;
alter table network_realizations add constraint network_realizations_parent_fk
  foreign key (parent_realization_id) references active_network_realizations (id);

create unique index network_realizations_unique_name
  on network_realizations (tenant, name) where deletion_timestamp = 'epoch';
-- The separate keys make the VPC intent unique per VN/site/config and the Prefix
-- intent unique per Subnet/parent. Both include the OSAC tenant, independently of NICo tenancy.
create unique index network_realizations_unique_virtual_network
  on network_realizations (
    tenant,
    (data->'spec'->>'osac_virtual_network_id'),
    (data->'spec'->>'site_id'),
    (data->'spec'->>'network_config_ref')
  ) where deletion_timestamp = 'epoch' and coalesce(data->'spec'->>'osac_subnet_id', '') = '';
create unique index network_realizations_unique_subnet
  on network_realizations (
    tenant,
    (data->'spec'->>'osac_subnet_id'),
    (data->'spec'->>'parent_realization_id')
  ) where deletion_timestamp = 'epoch' and coalesce(data->'spec'->>'osac_subnet_id', '') <> '';
create unique index network_realizations_unique_provider_name
  on network_realizations (
    (data->'spec'->>'site_id'),
    (data->'spec'->>'network_config_ref'),
    (data->'spec'->>'provider_name')
  ) where deletion_timestamp = 'epoch';
create index network_realizations_by_creator on network_realizations (creator);
create index network_realizations_by_label on network_realizations using gin (labels);
alter table network_realizations add constraint network_realizations_tenant_fk
  foreign key (tenant) references tenants (name);
alter table network_realizations add constraint network_realizations_project_fk
  foreign key (tenant, project) references projects (tenant, name);
create trigger check_immutable_columns before update on network_realizations
  for each row execute function check_immutable_columns('id', 'name', 'tenant', 'project');
create trigger materialize_active_objects after insert or update of deletion_timestamp on network_realizations
  for each row execute function materialize_active_objects();
create trigger enqueue_change after insert or update or delete on network_realizations
  for each row execute function enqueue_change();
