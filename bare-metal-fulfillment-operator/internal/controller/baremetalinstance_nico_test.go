package controller

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"github.com/osac-project/osac/bare-metal-fulfillment-operator/api/v1alpha1"
	"github.com/osac-project/osac/bare-metal-fulfillment-operator/internal/inventory"
	opv1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
	"github.com/osac-project/osac/osac-operator/pkg/provisioning"
)

type nicoPilotProvider struct {
	mockProvisioningProvider
	launches int
	outputs  map[string]any
}

func (p *nicoPilotProvider) TriggerProvisionWithExtraVars(_ context.Context, _ client.Object, vars map[string]any) (*provisioning.ProvisionResult, error) {
	Expect(vars["nico_bmaas_create_allowed"]).To(BeTrue())
	p.launches++
	return &provisioning.ProvisionResult{JobID: "nico-create-1", InitialState: opv1alpha1.JobStatePending}, nil
}

func (p *nicoPilotProvider) GetProvisionStatusWithExtraVars(_ context.Context, _ client.Object, jobID string) (provisioning.ProvisionStatusWithExtraVars, error) {
	return provisioning.ProvisionStatusWithExtraVars{
		ProvisionStatus: provisioning.ProvisionStatus{JobID: jobID, State: opv1alpha1.JobStateSucceeded},
		ExtraVars:       p.outputs,
	}, nil
}

func (p *nicoPilotProvider) GetDeprovisionStatusWithExtraVars(_ context.Context, _ client.Object, jobID string) (provisioning.ProvisionStatusWithExtraVars, error) {
	return provisioning.ProvisionStatusWithExtraVars{
		ProvisionStatus: provisioning.ProvisionStatus{JobID: jobID, State: opv1alpha1.JobStateSucceeded},
		ExtraVars: map[string]any{
			"nicoInstanceID":    "nico-instance-1",
			"nicoMachineID":     "nico-machine-1",
			"nicoCleanupStatus": "Released",
		},
	}, nil
}

var _ = Describe("NICo BareMetalInstance lifecycle", func() {
	var bmi *v1alpha1.BareMetalInstance
	var reconciler *BareMetalInstanceReconciler
	var provider *nicoPilotProvider
	var req ctrl.Request

	BeforeEach(func() {
		provider = &nicoPilotProvider{outputs: map[string]any{
			"nicoInstanceID": "nico-instance-1", "nicoMachineID": "nico-machine-1", "nicoIPAddress": "10.217.98.2",
		}}
		bmi = &v1alpha1.BareMetalInstance{
			ObjectMeta: metav1.ObjectMeta{
				GenerateName: "nico-bmi-pilot-", Namespace: "default",
				Annotations: map[string]string{
					"osac.openshift.io/tenant":          "pilot-tenant",
					"osac.openshift.io/owner-reference": "BareMetalInstance/nico-bmi-pilot",
				},
			},
			Spec: v1alpha1.BareMetalInstanceSpec{
				TemplateID:         nicoBMaaSTemplateID,
				Selector:           v1alpha1.HostSelectorSpec{HostSelector: map[string]string{"managedBy": "nico"}},
				NetworkAttachments: []v1alpha1.BareMetalNetworkAttachment{{SubnetRef: "osac-pilot-subnet", Interface: "eno1", Primary: true}},
			},
		}
		Expect(k8sClient.Create(ctx, bmi)).To(Succeed())
		req = ctrl.Request{NamespacedName: client.ObjectKeyFromObject(bmi)}
		reconciler = NewBareMetalInstanceReconciler(
			k8sClient, k8sClient.Scheme(),
			&mockInventoryClient{
				findFreeHostFunc: func(context.Context, map[string]string) (*inventory.Host, error) {
					return nil, fmt.Errorf("generic NICo inventory path must not run")
				},
				assignHostFunc: func(context.Context, string, string, map[string]string) (*inventory.Host, error) {
					return nil, fmt.Errorf("generic NICo host assignment must not run")
				},
			},
			nil, provider, nil, nil, nil, 0, 0, 0, time.Millisecond, 0,
		)
	})

	AfterEach(func() {
		fresh := &v1alpha1.BareMetalInstance{}
		if k8sClient.Get(ctx, req.NamespacedName, fresh) == nil {
			fresh.Finalizers = nil
			_ = k8sClient.Update(ctx, fresh)
			_ = k8sClient.Delete(ctx, fresh)
		}
	})

	reconcile := func() *v1alpha1.BareMetalInstance {
		_, err := reconciler.Reconcile(ctx, req)
		Expect(err).NotTo(HaveOccurred())
		fresh := &v1alpha1.BareMetalInstance{}
		Expect(k8sClient.Get(ctx, req.NamespacedName, fresh)).To(Succeed())
		return fresh
	}

	It("persists one create intent, saves both IDs, and removes its finalizer only after verified cleanup", func() {
		fresh := reconcile() // management finalizer
		Expect(controllerutil.ContainsFinalizer(fresh, BareMetalInstanceManagementFinalizer)).To(BeTrue())
		Expect(fresh.Status.NicoCreateAttempted).To(BeFalse())
		fresh = reconcile() // durable marker, then one AAP create launch
		Expect(fresh.Status.NicoCreateAttempted).To(BeTrue())
		Expect(provider.launches).To(Equal(1))
		Expect(fresh.Status.ProvisioningJobs).To(HaveLen(1))
		fresh = reconcile() // AAP artifacts
		Expect(fresh.Status.NicoInstanceID).To(Equal("nico-instance-1"))
		Expect(fresh.Status.NicoMachineID).To(Equal("nico-machine-1"))
		Expect(fresh.Spec.ExternalHostID).To(Equal("nico-machine-1"))
		Expect(fresh.Status.Phase).To(Equal(v1alpha1.BareMetalInstancePhaseReady))
		Expect(fresh.Status.NetworkAttachmentStatuses[0].IPAddress).To(Equal("10.217.98.2"))
		Expect(v1alpha1.DeriveProvisioningProgress(fresh.Status.Conditions).State).To(Equal(v1alpha1.StateReady))
		fresh = reconcile() // idempotent: no extra AAP launch
		Expect(fresh.Status.Phase).To(Equal(v1alpha1.BareMetalInstancePhaseReady))
		Expect(provider.launches).To(Equal(1))

		Expect(k8sClient.Delete(ctx, fresh)).To(Succeed())
		fresh = reconcile() // launch deprovision
		Expect(controllerutil.ContainsFinalizer(fresh, BareMetalInstanceManagementFinalizer)).To(BeTrue())
		_, err := reconciler.Reconcile(ctx, req) // successful deprovision artifacts
		Expect(err).NotTo(HaveOccurred())
		Expect(k8sClient.Get(ctx, req.NamespacedName, &v1alpha1.BareMetalInstance{})).ToNot(Succeed())
	})

	It("retains the finalizer when AAP succeeds without provider identifiers", func() {
		provider.outputs = map[string]any{}
		reconcile()
		reconcile()
		fresh := reconcile()
		Expect(fresh.Status.Phase).To(Equal(v1alpha1.BareMetalInstancePhaseFailed))
		Expect(fresh.Status.NicoCreateAttempted).To(BeTrue())
		Expect(provider.launches).To(Equal(1))
		Expect(k8sClient.Delete(ctx, fresh)).To(Succeed())
		_, err := reconciler.Reconcile(ctx, req)
		Expect(err).To(HaveOccurred())
		Expect(k8sClient.Get(ctx, req.NamespacedName, fresh)).To(Succeed())
		Expect(controllerutil.ContainsFinalizer(fresh, BareMetalInstanceManagementFinalizer)).To(BeTrue())
	})

	It("releases a BMI deleted before any NICo create attempt", func() {
		fresh := reconcile() // install the cleanup finalizer
		Expect(fresh.Status.NicoCreateAttempted).To(BeFalse())
		Expect(k8sClient.Delete(ctx, fresh)).To(Succeed())
		_, err := reconciler.Reconcile(ctx, req)
		Expect(err).NotTo(HaveOccurred())
		Expect(k8sClient.Get(ctx, req.NamespacedName, &v1alpha1.BareMetalInstance{})).ToNot(Succeed())
		Expect(provider.launches).To(BeZero())
	})
})
