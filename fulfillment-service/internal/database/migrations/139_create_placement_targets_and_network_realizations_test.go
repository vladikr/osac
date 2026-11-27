/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

package migrations

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgconn"
	. "github.com/onsi/ginkgo/v2/dsl/core"
	. "github.com/onsi/gomega"
)

var _ = DescribeMigration("Create placement targets and network realizations", func() {
	BeforeEach(func(ctx context.Context) {
		Expect(tool.Migrate(ctx, 139)).To(Succeed())
		_, err := conn.Exec(ctx, `
			insert into tenants (id, name, tenant, creator, data)
			values ('tenant-a', 'tenant-a', 'tenant-a', 'system', '{}'),
			       ('tenant-b', 'tenant-b', 'tenant-b', 'system', '{}')`)
		Expect(err).ToNot(HaveOccurred())
	})

	It("keeps placement registrations tenant-scoped while allowing multiple capacity targets", func(ctx context.Context) {
		_, err := conn.Exec(ctx, `
			insert into bare_metal_placement_targets (id, name, tenant, data)
			values
			  ('target-a', 'site-a', 'tenant-a', '{"spec":{"osac_instance_type_id":"gb300"}}'),
			  ('target-b', 'site-b', 'tenant-a', '{"spec":{"osac_instance_type_id":"gb300"}}'),
			  ('target-c', 'site-a', 'tenant-b', '{"spec":{"osac_instance_type_id":"gb300"}}')`)
		Expect(err).ToNot(HaveOccurred())
		_, err = conn.Exec(ctx, `
			insert into bare_metal_placement_targets (id, name, tenant, data)
			values ('duplicate', 'site-a', 'tenant-a', '{}')`)
		var pgErr *pgconn.PgError
		Expect(errors.As(err, &pgErr)).To(BeTrue())
		Expect(pgErr.Code).To(Equal("23505"))
	})

	It("deduplicates VPC and Prefix intents without mixing OSAC tenants", func(ctx context.Context) {
		vpc := `{"spec":{"osac_virtual_network_id":"vn-1","site_id":"site-a","network_config_ref":"fnn-a","provider_name":"osac-tenant-a-vn-1"}}`
		otherTenantVPC := `{"spec":{"osac_virtual_network_id":"vn-1","site_id":"site-a","network_config_ref":"fnn-a","provider_name":"osac-tenant-b-vn-1"}}`
		_, err := conn.Exec(ctx, `
			insert into network_realizations (id, name, tenant, data)
			values ('vpc-a', 'vpc-a', 'tenant-a', $1), ('vpc-b', 'vpc-b', 'tenant-b', $2)`, vpc, otherTenantVPC)
		Expect(err).ToNot(HaveOccurred())
		_, err = conn.Exec(ctx, `
			insert into network_realizations (id, name, tenant, data)
			values ('vpc-duplicate', 'vpc-duplicate', 'tenant-a', $1)`, vpc)
		var pgErr *pgconn.PgError
		Expect(errors.As(err, &pgErr)).To(BeTrue())
		Expect(pgErr.Code).To(Equal("23505"))

		prefix := `{"spec":{"osac_virtual_network_id":"vn-1","osac_subnet_id":"subnet-1","parent_realization_id":"vpc-a","site_id":"site-a","network_config_ref":"fnn-a","provider_name":"osac-subnet-1"}}`
		_, err = conn.Exec(ctx, `
			insert into network_realizations (id, name, tenant, data)
			values ('prefix-a', 'prefix-a', 'tenant-a', $1)`, prefix)
		Expect(err).ToNot(HaveOccurred())
		_, err = conn.Exec(ctx, `
			insert into network_realizations (id, name, tenant, data)
			values ('prefix-duplicate', 'prefix-duplicate', 'tenant-a', $1)`, prefix)
		Expect(errors.As(err, &pgErr)).To(BeTrue())
		Expect(pgErr.Code).To(Equal("23505"))
		_, err = conn.Exec(ctx, `update network_realizations set deletion_timestamp = now() where id = 'vpc-a'`)
		Expect(errors.As(err, &pgErr)).To(BeTrue())
		Expect(pgErr.Code).To(Equal("23503"))
	})
})
