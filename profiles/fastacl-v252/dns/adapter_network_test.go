package main
import (
 "context"
 "net"
 "testing"
 "time"
 "github.com/daeuniverse/outbound/netproxy"
)
func TestEncryptedBaseMagicNetwork(t *testing.T) {
 l,e:=net.Listen("tcp4","127.0.0.1:0");if e!=nil {t.Fatal(e)};defer l.Close()
 done:=make(chan error,1)
 go func(){c,e:=l.Accept();if e==nil {defer c.Close();_,e=c.Write([]byte{42})};done<-e}()
 ctx,cancel:=context.WithTimeout(context.Background(),time.Second);defer cancel()
 c,e:=(encryptedBase{}).DialContext(ctx,(netproxy.MagicNetwork{Network:"tcp",IPVersion:"4"}).Encode(),l.Addr().String());if e!=nil {t.Fatal(e)};defer c.Close()
 b:=make([]byte,1);if _,e=c.Read(b);e!=nil||b[0]!=42 {t.Fatalf("read %v %v",b,e)}
 if e=<-done;e!=nil {t.Fatal(e)}
}
