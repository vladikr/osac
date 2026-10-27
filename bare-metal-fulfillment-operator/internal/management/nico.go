package management

import (
	"context"
	"fmt"
)

// NICo owns Machine power as part of the Instance lifecycle. The pilot does
// not implement independent OSAC halt or restart requests.
type nicoClient struct{}

func init() {
	newClientFuncs["nico"] = func(context.Context, *Config) (Client, error) { return nicoClient{}, nil }
}

func (nicoClient) GetPowerState(context.Context, string) (*PowerStatus, error) {
	return nil, fmt.Errorf("NICo Machine power is managed through the Instance API")
}

func (nicoClient) SetPowerState(context.Context, string, PowerState) error {
	return fmt.Errorf("NICo Machine power is managed through the Instance API")
}

func (nicoClient) TriggerRestart(context.Context, string) error {
	return fmt.Errorf("NICo Machine restart is not supported by the BMI pilot")
}

func (nicoClient) IsRestartComplete(context.Context, string) (bool, error) {
	return false, fmt.Errorf("NICo Machine restart is not supported by the BMI pilot")
}
