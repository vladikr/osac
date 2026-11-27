/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
the License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
*/

package baremetalinstance

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/fieldmaskpb"

	bmfov1alpha1 "github.com/osac-project/osac/bare-metal-fulfillment-operator/api/v1alpha1"
	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

// Stable IDs let a reconciler recover after losing the response to Create.
// The database's natural-key uniqueness constraints also protect against a
// competing BMI creating the same realization with a different ID.
func nicoRealizationID(parts ...string) string {
	h := sha256.New()
	for _, part := range parts {
		_, _ = h.Write([]byte(part))
		_, _ = h.Write([]byte{0})
	}
	return "nr-" + hex.EncodeToString(h.Sum(nil)[:16])
}

func (t *task) validatePinnedNicoTarget(ctx context.Context) error {
	status := t.bareMetalInstance.GetStatus()
	response, err := t.r.placementTargetsClient.Get(ctx, privatev1.BareMetalPlacementTargetsGetRequest_builder{Id: status.GetPlacementTargetId()}.Build())
	if err != nil {
		return fmt.Errorf("read pinned NICo placement target: %w", err)
	}
	target := response.GetObject()
	if target.GetMetadata().GetDeletionTimestamp() != nil || target.GetMetadata().GetTenant() != t.bareMetalInstance.GetMetadata().GetTenant() ||
		!target.GetStatus().GetReady() || (status.GetPlacementNicoInstanceTypeId() == "" &&
		target.GetStatus().GetValidatedFingerprint() != status.GetPlacementTargetFingerprint()) ||
		target.GetSpec().GetSiteId() != status.GetPlacementSiteId() ||
		target.GetSpec().GetNetworkConfigRef() != status.GetPlacementNetworkConfigRef() ||
		target.GetSpec().GetProviderConfigRef() != status.GetPlacementProviderConfigRef() {
		return fmt.Errorf("pinned NICo placement target changed or is not Ready")
	}
	return nil
}

func (t *task) nicoRealizationSpecs(ctx context.Context) (vpcID, prefixID string, vpcSpec, prefixSpec *privatev1.NetworkRealizationSpec, err error) {
	attachments := t.bareMetalInstance.GetSpec().GetNetworkAttachments()
	if len(attachments) != 1 || attachments[0].GetSubnet().GetId() == "" {
		return "", "", nil, nil, fmt.Errorf("NICo placement requires one resolved Subnet")
	}
	subnetID := attachments[0].GetSubnet().GetId()
	response, err := t.r.subnetsClient.Get(ctx, privatev1.SubnetsGetRequest_builder{Id: subnetID}.Build())
	if err != nil {
		return "", "", nil, nil, fmt.Errorf("read NICo BMI Subnet: %w", err)
	}
	subnet := response.GetObject()
	tenant := t.bareMetalInstance.GetMetadata().GetTenant()
	if subnet.GetMetadata().GetTenant() != tenant || subnet.GetMetadata().GetDeletionTimestamp() != nil {
		return "", "", nil, nil, fmt.Errorf("NICo BMI Subnet is absent or no longer owned by its tenant")
	}
	vnID := subnet.GetSpec().GetVirtualNetwork().GetId()
	site := t.bareMetalInstance.GetStatus().GetPlacementSiteId()
	config := t.bareMetalInstance.GetStatus().GetPlacementNetworkConfigRef()
	if vnID == "" || site == "" || config == "" {
		return "", "", nil, nil, fmt.Errorf("NICo placement has no parent VirtualNetwork, site, or network configuration")
	}
	vpcID = nicoRealizationID(tenant, vnID, site, config, "vpc")
	prefixID = nicoRealizationID(tenant, subnetID, vpcID, "prefix")
	vpcSpec = &privatev1.NetworkRealizationSpec{
		OsacTenantId: tenant, OsacVirtualNetworkId: vnID, SiteId: site,
		NetworkConfigRef: config, ProviderName: "osac-" + vnID,
		Ownership: privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_OSAC_CREATED,
	}
	prefixSpec = &privatev1.NetworkRealizationSpec{
		OsacTenantId: tenant, OsacVirtualNetworkId: vnID, OsacSubnetId: subnetID,
		ParentRealizationId: vpcID, SiteId: site, NetworkConfigRef: config,
		RequestedCidr: subnet.GetSpec().GetIpv4Cidr(), ProviderName: "osac-" + subnetID,
		Ownership: privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_OSAC_CREATED,
	}
	return
}

func (t *task) ensureNicoNetworkRealizations(ctx context.Context) error {
	vpcID, prefixID, vpcSpec, prefixSpec, err := t.nicoRealizationSpecs(ctx)
	if err != nil {
		return err
	}
	t.nicoVpcRealizationID, t.nicoPrefixRealizationID = vpcID, prefixID
	if err := t.ensureNicoRealization(ctx, vpcID, vpcSpec); err != nil {
		return err
	}
	return t.ensureNicoRealization(ctx, prefixID, prefixSpec)
}

func (t *task) ensureNicoRealization(ctx context.Context, id string, spec *privatev1.NetworkRealizationSpec) error {
	current, err := t.r.networkRealizationsClient.Get(ctx, privatev1.NetworkRealizationsGetRequest_builder{Id: id}.Build())
	if status.Code(err) == codes.NotFound {
		_, err = t.r.networkRealizationsClient.Create(ctx, privatev1.NetworkRealizationsCreateRequest_builder{
			Object: &privatev1.NetworkRealization{
				Id:       id,
				Metadata: &privatev1.Metadata{Name: id, Tenant: spec.GetOsacTenantId(), Project: t.bareMetalInstance.GetMetadata().GetProject()},
				Spec:     spec,
			},
		}.Build())
		if err == nil {
			return nil
		}
		if status.Code(err) != codes.AlreadyExists {
			return fmt.Errorf("persist NICo network intent %s: %w", id, err)
		}
		current, err = t.r.networkRealizationsClient.Get(ctx, privatev1.NetworkRealizationsGetRequest_builder{Id: id}.Build())
	}
	if err != nil {
		return fmt.Errorf("read NICo network intent %s: %w", id, err)
	}
	object := current.GetObject()
	if object.GetMetadata().GetDeletionTimestamp() != nil || !proto.Equal(object.GetSpec(), spec) ||
		object.GetStatus().GetState() == privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_DELETED ||
		object.GetStatus().GetState() == privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_FAILED {
		return fmt.Errorf("NICo network intent %s differs from the pinned placement or is unavailable", id)
	}
	return nil
}

func (t *task) recordReadyNicoNetworkRealizations(ctx context.Context, bmi *bmfov1alpha1.BareMetalInstance) error {
	if bmi.Status.NicoVpcID == "" || bmi.Status.NicoVpcPrefixID == "" {
		return fmt.Errorf("NICo job is Ready without confirmed VPC and Prefix IDs")
	}
	vpcID, prefixID, _, prefixSpec, err := t.nicoRealizationSpecs(ctx)
	if err != nil {
		return err
	}
	if err := t.markNicoRealizationReady(ctx, vpcID, bmi.Status.NicoVpcID, ""); err != nil {
		return err
	}
	return t.markNicoRealizationReady(ctx, prefixID, bmi.Status.NicoVpcPrefixID, prefixSpec.GetRequestedCidr())
}

func (t *task) markNicoRealizationReady(ctx context.Context, id, backendID, cidr string) error {
	response, err := t.r.networkRealizationsClient.Get(ctx, privatev1.NetworkRealizationsGetRequest_builder{Id: id}.Build())
	if err != nil {
		return fmt.Errorf("read NICo network realization %s: %w", id, err)
	}
	object := response.GetObject()
	if object.GetStatus().GetState() == privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_READY {
		if object.GetStatus().GetBackendResourceId() != backendID || object.GetStatus().GetObservedCidr() != cidr {
			return fmt.Errorf("NICo network realization %s differs from confirmed provider state", id)
		}
		return nil
	}
	object.SetStatus(&privatev1.NetworkRealizationStatus{
		State:             privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_READY,
		BackendResourceId: backendID, ObservedCidr: cidr,
	})
	_, err = t.r.networkRealizationsClient.Update(ctx, privatev1.NetworkRealizationsUpdateRequest_builder{
		Object: object, UpdateMask: &fieldmaskpb.FieldMask{Paths: []string{"status"}}, Lock: true,
	}.Build())
	if err != nil {
		return fmt.Errorf("record confirmed NICo network realization %s: %w", id, err)
	}
	return nil
}
