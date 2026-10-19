package main
import("bufio";"context";"fmt";"io";"net";"strings";"testing";"time")

func TestRealFrontToLandingChain(t *testing.T) {
 landing,e:=net.Listen("tcp4","127.0.0.1:0");if e!=nil{t.Fatal(e)};defer landing.Close()
 front,e:=net.Listen("tcp4","127.0.0.1:0");if e!=nil{t.Fatal(e)};defer front.Close()
 seen:=make(chan string,2)
 go func(){c,e:=landing.Accept();if e!=nil{return};defer c.Close();c.SetDeadline(time.Now().Add(5*time.Second));reader:=bufio.NewReader(c);line,_:=reader.ReadString('\n');seen<-line
  for {s,e:=reader.ReadString('\n');if e!=nil{return};if s=="\r\n"{break}}
  c.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
  payload:=make([]byte,1);if _,e:=io.ReadFull(reader,payload);e!=nil||payload[0]!=22{return};c.Write([]byte("CHAIN"))
 }()
 go func(){c,e:=front.Accept();if e!=nil{return};defer c.Close();c.SetDeadline(time.Now().Add(5*time.Second));h:=make([]byte,2);if _,e=io.ReadFull(c,h);e!=nil{return};m:=make([]byte,int(h[1]));io.ReadFull(c,m);c.Write([]byte{5,0})
  h=make([]byte,4);if _,e=io.ReadFull(c,h);e!=nil{return};var host string
  if h[3]==1 {b:=make([]byte,4);io.ReadFull(c,b);host=net.IP(b).String()} else if h[3]==3 {b:=make([]byte,1);io.ReadFull(c,b);s:=make([]byte,int(b[0]));io.ReadFull(c,s);host=string(s)}else{return}
  b:=make([]byte,2);io.ReadFull(c,b);dest:=net.JoinHostPort(host,fmt.Sprint(int(b[0])*256+int(b[1])));seen<-dest
  remote,e:=net.DialTimeout("tcp",dest,2*time.Second);if e!=nil{return};defer remote.Close();c.Write([]byte{5,0,0,1,0,0,0,0,0,0});go io.Copy(remote,c);io.Copy(c,remote)
 }()
 cfg:=Config{Exits:map[string]string{"12600":"http://"+landing.Addr().String()+" -> socks5://"+front.Addr().String()}}
 exits,e:=makeExits(cfg);if e!=nil{t.Fatal(e)};r:=&relay{exits:exits};ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second);defer cancel()
 c,e:=r.privateDial(ctx,12600,"9.9.9.9");if e!=nil{t.Fatal(e)};defer c.Close();c.SetDeadline(time.Now().Add(5*time.Second));if _,e=c.Write([]byte{22});e!=nil{t.Fatal(e)};b:=make([]byte,5);if _,e=io.ReadFull(c,b);e!=nil||string(b)!="CHAIN"{t.Fatal("chain did not reach landing",e)}
 a,z:=<-seen,<-seen;if a!=landing.Addr().String()||!strings.HasPrefix(z,"CONNECT 9.9.9.9:443 "){t.Fatal("wrong chain traversal",a,z)}
}
