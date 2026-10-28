package controller

import (
	"context"
	"fmt"
	"os"
	"strings"

	"sigs.k8s.io/yaml"

	"github.com/osac-project/osac/bare-metal-fulfillment-operator/api/v1alpha1"
	"github.com/osac-project/osac/osac-operator/pkg/provisioning"
)

// The binding file is an administrator-owned ConfigMap mount. It contains only
// OSAC resource IDs and AWX credential IDs; NICo credentials remain in AWX.
// The selected AWX credential independently checks the tenant and subnet IDs.
type nicoBindingsFile struct {
	Version  int                 `json:"version"`
	Bindings []nicoTenantBinding `json:"bindings"`
}

type nicoTenantBinding struct {
	OSACTenantID  string `json:"osacTenantID"`
	OSACSubnetID  string `json:"osacSubnetID"`
	CredentialIDs []int  `json:"credentialIDs"`
}

func (r *BareMetalInstanceReconciler) withNicoCredentials(ctx context.Context, bmi *v1alpha1.BareMetalInstance) (context.Context, error) {
	if r.NicoBindingsConfigPath == "" {
		return nil, fmt.Errorf("NICo tenant bindings are not configured")
	}
	if len(bmi.Spec.NetworkAttachments) != 1 {
		return nil, fmt.Errorf("NICo tenant binding requires one OSAC Subnet")
	}
	tenantID := bmi.Annotations["osac.openshift.io/tenant"]
	subnetID := bmi.Spec.NetworkAttachments[0].SubnetRef
	if tenantID == "" || subnetID == "" {
		return nil, fmt.Errorf("NICo tenant binding requires a BMI tenant and Subnet ID")
	}
	data, err := os.ReadFile(r.NicoBindingsConfigPath)
	if err != nil {
		return nil, fmt.Errorf("read NICo tenant bindings: %w", err)
	}
	var config nicoBindingsFile
	if err := yaml.UnmarshalStrict(data, &config); err != nil {
		return nil, fmt.Errorf("parse NICo tenant bindings: %w", err)
	}
	if config.Version != 1 || len(config.Bindings) == 0 {
		return nil, fmt.Errorf("NICo tenant bindings require version 1 and at least one binding")
	}
	seen := make(map[string]struct{}, len(config.Bindings))
	var selected *nicoTenantBinding
	for i := range config.Bindings {
		binding := &config.Bindings[i]
		if binding.OSACTenantID == "" || binding.OSACSubnetID == "" ||
			strings.TrimSpace(binding.OSACTenantID) != binding.OSACTenantID ||
			strings.TrimSpace(binding.OSACSubnetID) != binding.OSACSubnetID ||
			len(binding.CredentialIDs) == 0 {
			return nil, fmt.Errorf("NICo tenant binding %d is incomplete", i)
		}
		key := binding.OSACTenantID + "\x00" + binding.OSACSubnetID
		if _, exists := seen[key]; exists {
			return nil, fmt.Errorf("duplicate NICo tenant binding for one OSAC tenant and Subnet")
		}
		seen[key] = struct{}{}
		credentialIDs := make(map[int]struct{}, len(binding.CredentialIDs))
		for _, id := range binding.CredentialIDs {
			if id <= 0 {
				return nil, fmt.Errorf("NICo tenant binding %d has an invalid AWX credential ID", i)
			}
			if _, exists := credentialIDs[id]; exists {
				return nil, fmt.Errorf("NICo tenant binding %d repeats an AWX credential ID", i)
			}
			credentialIDs[id] = struct{}{}
		}
		if binding.OSACTenantID == tenantID && binding.OSACSubnetID == subnetID {
			selected = binding
		}
	}
	if selected == nil {
		return nil, fmt.Errorf("no NICo tenant binding for BMI tenant and Subnet")
	}
	return provisioning.WithAAPCredentialIDs(ctx, selected.CredentialIDs), nil
}
