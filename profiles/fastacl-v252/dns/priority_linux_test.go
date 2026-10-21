//go:build linux
package main
import("context";"net";"syscall";"testing";"time")
func TestPrioritySocketDSCP(t *testing.T){
 listener,e:=net.Listen("tcp4","127.0.0.1:0");if e!=nil{t.Fatal(e)};defer listener.Close();go func(){c,e:=listener.Accept();if e==nil{defer c.Close();var b [1]byte;c.Read(b[:])}}()
 ctx,cancel:=context.WithTimeout(context.Background(),time.Second);defer cancel();c,e:=(priorityBase{}).DialContext(ctx,"tcp",listener.Addr().String());if e!=nil{t.Fatal(e)};defer c.Close();raw,e:=c.(interface{SyscallConn()(syscall.RawConn,error)}).SyscallConn();if e!=nil{t.Fatal(e)};var tos int;raw.Control(func(fd uintptr){tos,e=syscall.GetsockoptInt(int(fd),syscall.IPPROTO_IP,syscall.IP_TOS)});if e!=nil||tos&252!=34<<2{t.Fatal(tos,e)}
}
