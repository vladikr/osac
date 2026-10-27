package inventory

import (
	"context"
	"fmt"
)

// NICo claims Machines when the tenant creates an Instance. The generic
// inventory interface has no tenant or Instance context, so every operation
// must fail rather than allocate or release a NICo Machine through this path.
type nicoClient struct{}

func init() {
	newClientFuncs["nico"] = func(context.Context, *Config) (Client, error) { return nicoClient{}, nil }
}

func (nicoClient) FindFreeHost(context.Context, map[string]string) (*Host, error) {
	return nil, fmt.Errorf("NICo Machines are allocated through the Instance API")
}

func (nicoClient) AssignHost(context.Context, string, string, map[string]string) (*Host, error) {
	return nil, fmt.Errorf("NICo Machines are allocated through the Instance API")
}

func (nicoClient) UnassignHost(context.Context, string, string, []string) error {
	return fmt.Errorf("NICo Machines are released through Instance cleanup")
}

func (nicoClient) GetHostNICs(context.Context, string) ([]HostNIC, error) {
	return nil, fmt.Errorf("NICo Machine interfaces are reported by the Instance API")
}

func (nicoClient) GetHostLogicalPortMACs(context.Context, string) (map[string]string, error) {
	return nil, fmt.Errorf("NICo Machine interfaces are reported by the Instance API")
}
