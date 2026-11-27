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
	"context"
	"log/slog"
	"net/netip"

	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	"github.com/osac-project/osac/fulfillment-service/internal/auth"
	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

// PrivateNetworkRealizationsServer persists intent before a provider create and observed identity after it.
type PrivateNetworkRealizationsServer struct {
	privatev1.UnimplementedNetworkRealizationsServer
	generic *GenericServer[*privatev1.NetworkRealization]
}

func NewPrivateNetworkRealizationsServer(logger *slog.Logger, attribution auth.AttributionLogic,
	tenancy auth.TenancyLogic, metrics prometheus.Registerer) (*PrivateNetworkRealizationsServer, error) {
	generic, err := NewGenericServer[*privatev1.NetworkRealization]().
		SetLogger(logger).
		SetService(privatev1.NetworkRealizations_ServiceDesc.ServiceName).
		SetAttributionLogic(attribution).
		SetTenancyLogic(tenancy).
		SetMetricsRegisterer(metrics).
		Build()
	if err != nil {
		return nil, err
	}
	return &PrivateNetworkRealizationsServer{generic: generic}, nil
}

func (s *PrivateNetworkRealizationsServer) List(ctx context.Context,
	request *privatev1.NetworkRealizationsListRequest) (response *privatev1.NetworkRealizationsListResponse, err error) {
	err = s.generic.List(ctx, request, &response)
	return
}

func (s *PrivateNetworkRealizationsServer) Get(ctx context.Context,
	request *privatev1.NetworkRealizationsGetRequest) (response *privatev1.NetworkRealizationsGetResponse, err error) {
	err = s.generic.Get(ctx, request, &response)
	return
}

func (s *PrivateNetworkRealizationsServer) Create(ctx context.Context,
	request *privatev1.NetworkRealizationsCreateRequest) (response *privatev1.NetworkRealizationsCreateResponse, err error) {
	err = s.generic.CreateWithCandidatePreparation(ctx, request, &response,
		func(ctx context.Context, _ *privatev1.NetworkRealization, candidate *privatev1.NetworkRealization) error {
			if err := validateRealizationSpec(candidate); err != nil {
				return err
			}
			if candidate.GetSpec().GetParentRealizationId() != "" {
				parentResult, err := s.generic.dao.Get().SetId(candidate.GetSpec().GetParentRealizationId()).Do(ctx)
				if err != nil {
					return ConvertDAOErrorToGRPC(err, "get", candidate.GetSpec().GetParentRealizationId())
				}
				parent := parentResult.GetObject()
				childSpec := candidate.GetSpec()
				parentSpec := parent.GetSpec()
				if parent.GetMetadata().GetDeletionTimestamp() != nil || parentSpec.GetOsacSubnetId() != "" ||
					parent.GetMetadata().GetTenant() != candidate.GetMetadata().GetTenant() ||
					parentSpec.GetOsacVirtualNetworkId() != childSpec.GetOsacVirtualNetworkId() ||
					parentSpec.GetSiteId() != childSpec.GetSiteId() ||
					parentSpec.GetNetworkConfigRef() != childSpec.GetNetworkConfigRef() {
					return status.Error(codes.FailedPrecondition, "subnet realization parent must be an active VirtualNetwork realization for the same tenant, network, site, and configuration")
				}
			}
			candidate.SetStatus(&privatev1.NetworkRealizationStatus{})
			candidate.GetStatus().SetState(privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_PENDING)
			return nil
		})
	return
}

func validateRealizationSpec(candidate *privatev1.NetworkRealization) error {
	spec := candidate.GetSpec()
	if spec == nil || candidate.GetMetadata().GetTenant() != spec.GetOsacTenantId() {
		return status.Error(codes.InvalidArgument, "realization tenant must match metadata.tenant")
	}
	isSubnet := spec.GetOsacSubnetId() != ""
	if isSubnet != (spec.GetParentRealizationId() != "") || isSubnet != (spec.GetRequestedCidr() != "") {
		return status.Error(codes.InvalidArgument, "subnet realization requires subnet, parent, and CIDR together")
	}
	if isSubnet {
		prefix, err := netip.ParsePrefix(spec.GetRequestedCidr())
		if err != nil || prefix.Masked() != prefix {
			return status.Error(codes.InvalidArgument, "requested CIDR must be canonical")
		}
	}
	if spec.GetOwnership() != privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_OSAC_CREATED &&
		spec.GetOwnership() != privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_ADOPTED {
		return status.Error(codes.InvalidArgument, "realization ownership is required")
	}
	adopted := spec.GetOwnership() == privatev1.NetworkRealizationOwnership_NETWORK_REALIZATION_OWNERSHIP_ADOPTED
	if adopted != (spec.GetAdoptedBackendResourceId() != "") {
		return status.Error(codes.InvalidArgument, "adopted realization requires a provider resource ID; OSAC-created realization must omit it")
	}
	return nil
}

func (s *PrivateNetworkRealizationsServer) Update(ctx context.Context,
	request *privatev1.NetworkRealizationsUpdateRequest) (response *privatev1.NetworkRealizationsUpdateResponse, err error) {
	err = s.generic.UpdateWithValidation(ctx, request, &response,
		func(_ context.Context, candidate, current *privatev1.NetworkRealization) error {
			if !proto.Equal(candidate.GetSpec(), current.GetSpec()) {
				return status.Error(codes.FailedPrecondition, "realization intent is immutable")
			}
			if current.GetStatus().GetBackendResourceId() != "" &&
				candidate.GetStatus().GetBackendResourceId() != current.GetStatus().GetBackendResourceId() {
				return status.Error(codes.FailedPrecondition, "verified provider resource ID is immutable")
			}
			if candidate.GetStatus().GetState() == privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_READY {
				if candidate.GetStatus().GetBackendResourceId() == "" {
					return status.Error(codes.InvalidArgument, "Ready realization requires a verified provider resource ID")
				}
				if adoptedID := candidate.GetSpec().GetAdoptedBackendResourceId(); adoptedID != "" &&
					candidate.GetStatus().GetBackendResourceId() != adoptedID {
					return status.Error(codes.InvalidArgument, "verified provider resource ID differs from adopted resource ID")
				}
				if candidate.GetSpec().GetOsacSubnetId() != "" && candidate.GetStatus().GetObservedCidr() != candidate.GetSpec().GetRequestedCidr() {
					return status.Error(codes.InvalidArgument, "observed subnet CIDR does not match requested CIDR")
				}
			}
			return nil
		})
	return
}

func (s *PrivateNetworkRealizationsServer) Delete(ctx context.Context,
	request *privatev1.NetworkRealizationsDeleteRequest) (response *privatev1.NetworkRealizationsDeleteResponse, err error) {
	// The provider reconciliation and network-parent deletion path will set DELETED only
	// after remote cleanup (or adopted-record release) has been confirmed.
	get, err := s.generic.dao.Get().SetId(request.GetId()).Do(ctx)
	if err != nil {
		return nil, ConvertDAOErrorToGRPC(err, "get", request.GetId())
	}
	if get.GetObject().GetStatus().GetState() != privatev1.NetworkRealizationState_NETWORK_REALIZATION_STATE_DELETED {
		return nil, status.Error(codes.FailedPrecondition, "provider cleanup must be confirmed before deleting a realization")
	}
	err = s.generic.Delete(ctx, request, &response)
	return
}
