package main
import("context";"time";"fmt";"github.com/daeuniverse/outbound/dialer";"os";"net";"path/filepath";"testing";"golang.org/x/net/dns/dnsmessage")
func platformRelay(t *testing.T)*relay{
 t.Helper();r:=domainRelay();p:=r.config.DevicePolicies["192.168.7.100"];p.Platforms=[]string{"youtube"};p.PlatformSlot="platform_test";r.config.DevicePolicies["192.168.7.100"]=p;r.platforms=map[string][]platformRule{"youtube":{{"domain","youtube.com"},{"full","exact.example.cn"}}};r.domestic["youtube.com"]=struct{}{};r.domestic["example.cn"]=struct{}{};r.platformMap=&platformStore{file:filepath.Join(t.TempDir(),"map.json"),platformDisk:platformDisk{Next:1,Rows:map[string]platformMapping{}}};return r
}
func TestPlatformWinsDomesticAndBlockWinsPlatform(t *testing.T){
 r:=platformRelay(t);id,exit,block:=r.domainPolicy("192.168.7.100",domainQuery("live.youtube.com"));if id!="foreign"||exit!=12600||block{t.Fatal(id,exit,block)}
 p:=r.config.DevicePolicies["192.168.7.100"];p.BlockDomains=append(p.BlockDomains,"youtube.com");r.config.DevicePolicies["192.168.7.100"]=p;_,_,block=r.domainPolicy("192.168.7.100",domainQuery("live.youtube.com"));if !block{t.Fatal("block bypassed")}
 if r.platformName(p,"youtube.com.evil.test")!=""||r.platformName(p,"sub.exact.example.cn")!=""{t.Fatal("domain boundary mismatch")}
}
func TestPlatformFakeAnswerOwnershipAndPersistence(t *testing.T){
 r:=platformRelay(t);q:=domainQuery("live.youtube.com");var msg dnsmessage.Message;if msg.Unpack(q)!=nil{t.Fatal("query")};msg.Response=true;msg.RecursionAvailable=true;msg.Answers=[]dnsmessage.Resource{{Header:dnsmessage.ResourceHeader{Name:msg.Questions[0].Name,Type:dnsmessage.TypeA,Class:dnsmessage.ClassINET,TTL:3600},Body:&dnsmessage.AResource{A:[4]byte{203,0,113,9}}}};b,_:=msg.Pack();out:=r.platformRewrite(q,b,"192.168.7.100");var got dnsmessage.Message;if got.Unpack(out)!=nil||len(got.Answers)!=1{t.Fatal("answer")};body:=got.Answers[0].Body.(*dnsmessage.AResource);fake:=net.IP(body.A[:]).String();if !isPlatformIP(fake)||got.Answers[0].Header.TTL!=60{t.Fatal(fake)}
 address,e:=r.platformAddress("platform_test",net.JoinHostPort(fake,"443"));if e!=nil||address!="203.0.113.9:443"{t.Fatal(address,e)}
 if _,e=r.platformAddress("platform_other",net.JoinHostPort(fake,"443"));e==nil{t.Fatal("cross-slot allowed")};if _,e=r.platformAddress("platform_test","198.19.200.200:443");e==nil{t.Fatal("unknown fake allowed")};if _,e=r.platformAddress("platform_test","203.0.113.9:443");e==nil{t.Fatal("unclassified allowed")}
 // Mapping is written before the reply becomes observable.
 if b,e:=os.ReadFile(r.platformMap.file);e!=nil||len(b)==0{t.Fatal("map not persisted",e)}
 q6:=append([]byte(nil),q...);q6[len(q6)-3]=28;reply6:=append([]byte(nil),q6...);reply6[2]|=128;out=r.platformRewrite(q6,reply6,"192.168.7.100");if got.Unpack(out)!=nil||len(got.Answers)!=0{t.Fatal("platform IPv6 escape")}
}
func TestPlatformTCPUDPForwarding(t *testing.T){
 m,address,r:=slotFixture(t);_ = m
 r.config.DataSlots=map[string]int{"platform_test":12600};r.priorityExits=r.exits;r.config.DevicePolicies=map[string]PolicyConfig{"127.0.0.1":{PlatformSlot:"platform_test",Platforms:[]string{"youtube"}}};r.platforms=map[string][]platformRule{"youtube":{{Kind:"domain",Value:"youtube.com"}}};r.platformMap=&platformStore{platformDisk:platformDisk{Rows:map[string]platformMapping{"198.19.0.1":{Slot:"platform_test",Real:"203.0.113.1",Platform:"youtube",Domain:"www.youtube.com"}}}}
 d,_,e:=dialer.NewNetproxyDialerFromLink(encryptedBase{},&dialer.ExtraOption{},fmt.Sprintf("socks5://platform_test:%s@%s",r.config.DataSecret,address));if e!=nil{t.Fatal(e)}
 for _,network:=range []string{"tcp","udp"}{
 ctx,cancel:=context.WithTimeout(context.Background(),2*time.Second);c,e:=d.DialContext(ctx,network,"198.19.0.1:1234");cancel();if e!=nil{t.Fatal(network,e)};c.SetDeadline(time.Now().Add(2*time.Second));c.Write([]byte("ping"));b:=make([]byte,65535);n,e:=c.Read(b);c.Close();if e!=nil||string(b[:n])!="A:ping"{t.Fatal(network,string(b[:n]),e)}
 }
}
