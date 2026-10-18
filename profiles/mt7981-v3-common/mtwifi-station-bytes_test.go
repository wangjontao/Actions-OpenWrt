package main
import("testing";"unsafe")
// These offsets are the ARM64 MTWiFi 7.6.6.1 vendor ioctl ABI, not a wire schema.
func TestDriverABI(t *testing.T){var s stat;var r request;if unsafe.Sizeof(s)!=72||unsafe.Offsetof(s.Tx)!=8||unsafe.Offsetof(s.Rx)!=16||unsafe.Offsetof(s.Valid)!=64{t.Fatal("station statistics ABI mismatch")};if unsafe.Sizeof(r)!=32||unsafe.Offsetof(r.Pointer)!=16||unsafe.Offsetof(r.Flags)!=26{t.Fatal("iwreq ABI mismatch")}}
