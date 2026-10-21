package main
import("context";"crypto/tls";"encoding/json";"fmt";"io";"net";"os";"testing";"time";"golang.org/x/net/dns/dnsmessage";"github.com/daeuniverse/outbound/dialer";"github.com/daeuniverse/outbound/netproxy")
func TestPlatformLiveProxy(t *testing.T){
 path:=os.Getenv("PLATFORM_TEST_CONFIG");if path==""{t.Skip("router-only real proxy test")};r,_,e:=loadRelay(path);if e!=nil{t.Fatal(e)}
 q:=domainQuery("www.youtube.com");b:=r.resolve(q,"127.0.0.1");var msg dnsmessage.Message;if msg.Unpack(b)!=nil||msg.RCode!=0||len(msg.Answers)==0{t.Fatal("platform DNS failed")};a:=msg.Answers[0].Body.(*dnsmessage.AResource);ip:=net.IP(a.A[:]).String();if !isPlatformIP(ip){t.Fatal("platform not forced")}
 m:=&relayManager{};m.publish(r);l,e:=m.serveSlots();if e!=nil{t.Fatal(e)};defer l.Close();d,_,e:=dialer.NewNetproxyDialerFromLink(encryptedBase{},&dialer.ExtraOption{},fmt.Sprintf("socks5://platform_test:%s@%s",r.config.DataSecret,l.Addr()));if e!=nil{t.Fatal(e)}
 ctx,cancel:=context.WithTimeout(context.Background(),15*time.Second);defer cancel();conn,e:=d.DialContext(ctx,"tcp",ip+":443");if e!=nil{t.Fatal(e)};defer conn.Close();conn.SetDeadline(time.Now().Add(15*time.Second));tc:=tls.Client(&netproxy.FakeNetConn{Conn:conn,LAddr:&net.TCPAddr{},RAddr:&net.TCPAddr{}},&tls.Config{ServerName:"www.youtube.com",MinVersion:tls.VersionTLS12});defer tc.Close();if e=tc.HandshakeContext(ctx);e!=nil{t.Fatal(e)};io.WriteString(tc,"HEAD / HTTP/1.1\r\nHost: www.youtube.com\r\nConnection: close\r\n\r\n");data:=make([]byte,256);n,e:=tc.Read(data);if n==0{t.Fatal(e)};if string(data[:5])!="HTTP/"{t.Fatal("not HTTP")};t.Log("Real proxy DNS -> platform address -> authenticated TCP -> valid YouTube TLS/HTTP")
}
var _=json.Valid
