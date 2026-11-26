//go:build !darwin

package netlocation

// Gateways returns ErrUnsupported: detection is implemented only on macOS.
func Gateways() ([]string, error) {
	return nil, ErrUnsupported
}
