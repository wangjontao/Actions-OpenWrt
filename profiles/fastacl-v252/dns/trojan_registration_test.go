package main

import "testing"

func TestTrojanProtocolRegistration(t *testing.T) {
 cfg:=Config{Exits:map[string]string{
  "12600":"trojan://test-password@127.0.0.1:443?allowInsecure=1&security=tls&sni=example.com",
 }}
 exits,err:=makeExits(cfg)
 if err!=nil {t.Fatalf("trojan node must build a DNS relay exit: %v",err)}
 if exits[12600]==nil {t.Fatal("trojan exit 12600 was not created")}
}
