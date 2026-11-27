/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

package servers

import (
	"testing"

	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

func TestValidateRealizationSpec(t *testing.T) {
	newRealization := func() *privatev1.NetworkRealization {
		return &privatev1.NetworkRealization{
			Metadata: &privatev1.Metadata{Tenant: "tenant-a", Name: "network-a"},
			Spec: &privatev1.NetworkRealizationSpec{
				OsacTenantId:         "tenant-a",
				OsacVirtualNetworkId: "vn-a",
				SiteId:               "site-a",
				NetworkConfigRef:     "fnn-a",
				ProviderName:         "osac-vn-a",
				Ownership:            privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_OSAC_CREATED,
			},
		}
	}
	tests := []struct {
		name   string
		change func(*privatev1.NetworkRealization)
		valid  bool
	}{
		{"virtual network intent", func(*privatev1.NetworkRealization) {}, true},
		{"subnet intent", func(r *privatev1.NetworkRealization) {
			r.Spec.OsacSubnetId = "subnet-a"
			r.Spec.ParentRealizationId = "vpc-realization-a"
			r.Spec.RequestedCidr = "10.181.0.32/28"
		}, true},
		{"tenant mismatch", func(r *privatev1.NetworkRealization) { r.Metadata.Tenant = "tenant-b" }, false},
		{"missing parent", func(r *privatev1.NetworkRealization) {
			r.Spec.OsacSubnetId = "subnet-a"
			r.Spec.RequestedCidr = "10.181.0.32/28"
		}, false},
		{"noncanonical CIDR", func(r *privatev1.NetworkRealization) {
			r.Spec.OsacSubnetId = "subnet-a"
			r.Spec.ParentRealizationId = "vpc-realization-a"
			r.Spec.RequestedCidr = "10.181.0.33/28"
		}, false},
		{"adopted identity missing", func(r *privatev1.NetworkRealization) {
			r.Spec.Ownership = privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_ADOPTED
		}, false},
		{"adopted identity supplied", func(r *privatev1.NetworkRealization) {
			r.Spec.Ownership = privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_ADOPTED
			r.Spec.AdoptedBackendResourceId = "vpc-123"
		}, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := newRealization()
			tc.change(r)
			err := validateRealizationSpec(r)
			if tc.valid && err != nil {
				t.Fatalf("expected valid intent: %v", err)
			}
			if !tc.valid && err == nil {
				t.Fatal("expected invalid intent to be rejected")
			}
		})
	}
}
