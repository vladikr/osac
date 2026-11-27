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
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	"github.com/osac-project/osac/fulfillment-service/internal/auth"
	"github.com/osac-project/osac/fulfillment-service/internal/database/dao"
	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

// PrivateBareMetalPlacementTargetsServer stores provider-owned capacity registrations.
// Validation and placement are separate controllers; a new target is never Ready on create.
type PrivateBareMetalPlacementTargetsServer struct {
	privatev1.UnimplementedBareMetalPlacementTargetsServer
	generic               *GenericServer[*privatev1.BareMetalPlacementTarget]
	bareMetalInstancesDao *dao.GenericDAO[*privatev1.BareMetalInstance]
}

func NewPrivateBareMetalPlacementTargetsServer(logger *slog.Logger, attribution auth.AttributionLogic,
	tenancy auth.TenancyLogic, metrics prometheus.Registerer) (*PrivateBareMetalPlacementTargetsServer, error) {
	generic, err := NewGenericServer[*privatev1.BareMetalPlacementTarget]().
		SetLogger(logger).
		SetService(privatev1.BareMetalPlacementTargets_ServiceDesc.ServiceName).
		SetAttributionLogic(attribution).
		SetTenancyLogic(tenancy).
		SetMetricsRegisterer(metrics).
		Build()
	if err != nil {
		return nil, err
	}
	bmis, err := dao.NewGenericDAO[*privatev1.BareMetalInstance]().SetLogger(logger).SetTenancyLogic(tenancy).Build()
	if err != nil {
		return nil, err
	}
	return &PrivateBareMetalPlacementTargetsServer{generic: generic, bareMetalInstancesDao: bmis}, nil
}

func (s *PrivateBareMetalPlacementTargetsServer) List(ctx context.Context,
	request *privatev1.BareMetalPlacementTargetsListRequest) (response *privatev1.BareMetalPlacementTargetsListResponse, err error) {
	err = s.generic.List(ctx, request, &response)
	return
}

func (s *PrivateBareMetalPlacementTargetsServer) Get(ctx context.Context,
	request *privatev1.BareMetalPlacementTargetsGetRequest) (response *privatev1.BareMetalPlacementTargetsGetResponse, err error) {
	err = s.generic.Get(ctx, request, &response)
	return
}

// Validate the approved offering-to-pool choices before they can participate in placement.
func validatePlacementMappings(spec *privatev1.BareMetalPlacementTargetSpec) error {
	if spec.GetOsacInstanceTypeId() != "" || len(spec.GetInstanceTypeMappings()) == 0 {
		return status.Error(codes.InvalidArgument, "configure instance_type_mappings for this target")
	}
	seen := make(map[string]bool)
	for _, m := range spec.GetInstanceTypeMappings() {
		if seen[m.GetOsacInstanceTypeId()] {
			return status.Error(codes.InvalidArgument, "each OSAC instance type must map to one pool per target")
		}
		seen[m.GetOsacInstanceTypeId()] = true
	}
	return nil
}

func (s *PrivateBareMetalPlacementTargetsServer) Create(ctx context.Context,
	request *privatev1.BareMetalPlacementTargetsCreateRequest) (response *privatev1.BareMetalPlacementTargetsCreateResponse, err error) {
	err = s.generic.CreateWithCandidatePreparation(ctx, request, &response,
		func(_ context.Context, _ *privatev1.BareMetalPlacementTarget, candidate *privatev1.BareMetalPlacementTarget) error {
			if candidate.GetSpec() == nil || candidate.GetMetadata().GetTenant() != candidate.GetSpec().GetOsacTenantId() {
				return status.Error(codes.InvalidArgument, "placement target tenant must match metadata.tenant")
			}
			if err := validatePlacementMappings(candidate.GetSpec()); err != nil {
				return err
			}
			candidate.SetStatus(&privatev1.BareMetalPlacementTargetStatus{})
			return nil
		})
	return
}

func (s *PrivateBareMetalPlacementTargetsServer) Update(ctx context.Context,
	request *privatev1.BareMetalPlacementTargetsUpdateRequest) (response *privatev1.BareMetalPlacementTargetsUpdateResponse, err error) {
	err = s.generic.UpdateWithValidation(ctx, request, &response,
		func(_ context.Context, candidate, current *privatev1.BareMetalPlacementTarget) error {
			if proto.Equal(candidate.GetSpec(), current.GetSpec()) {
				return nil
			}
			if err := validatePlacementMappings(candidate.GetSpec()); err != nil {
				return err
			}
			updated := proto.Clone(current.GetSpec()).(*privatev1.BareMetalPlacementTargetSpec)
			updated.SetOsacInstanceTypeId("")
			updated.SetInstanceTypeMappings(candidate.GetSpec().GetInstanceTypeMappings())
			if !proto.Equal(candidate.GetSpec(), updated) {
				return status.Error(codes.FailedPrecondition, "target tenant, site and configuration references are immutable")
			}
			candidate.SetStatus(&privatev1.BareMetalPlacementTargetStatus{})
			return nil
		})
	return
}

func (s *PrivateBareMetalPlacementTargetsServer) Delete(ctx context.Context,
	request *privatev1.BareMetalPlacementTargetsDeleteRequest) (response *privatev1.BareMetalPlacementTargetsDeleteResponse, err error) {
	filter := "this.status.placement_target_id == " + strconv.Quote(request.GetId())
	used, err := s.bareMetalInstancesDao.List().SetFilter(filter).SetLimit(0).Do(ctx)
	if err != nil {
		return nil, ConvertDAOErrorToGRPC(err, "list", "bare metal instances")
	}
	if used.GetTotal() > 0 {
		return nil, status.Error(codes.FailedPrecondition, "placement target is referenced by a bare metal instance")
	}
	err = s.generic.Delete(ctx, request, &response)
	return
}
