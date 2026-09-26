import 'dart:convert';

String _b64(String s) => base64.encode(utf8.encode(s));

// Made-up servers in every format the parsers take. Hosts are *.example / TEST-NET.

const vlessReality =
    'vless://11111111-2222-3333-4444-555555555555@de1.example:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Frankfurt%2001';
const vlessWs = 'vless://11111111-2222-3333-4444-555555555555@nl1.example:8443?type=ws&security=tls&path=%2Fws%3Fed%3D2048&host=cdn.example&sni=cdn.example#NL%20WS';
// Same server as vlessWs, different connection variant (no early data, different path/host/sni).
const vlessWsVariant =
    'vless://11111111-2222-3333-4444-555555555555@nl1.example:8443?type=ws&security=tls&path=%2Fws2&host=cdn2.example&sni=cdn2.example#NL%20WS%202';
const vlessXhttp = 'vless://11111111-2222-3333-4444-555555555555@fi1.example:443?type=xhttp&security=reality&pbk=abc&sni=a.example#FI%20XHTTP';
const trojanGrpc = 'trojan://secret-pass@se1.example:443?type=grpc&serviceName=tun&sni=se1.example#SE';
final ssSip002 = 'ss://${_b64('aes-256-gcm:password')}@192.0.2.10:8388#PL%20SS';
const ss2022 = 'ss://2022-blake3-aes-128-gcm:AAAAAAAAAAAAAAAAAAAAAA%3D%3D@192.0.2.11:8389#SS2022';
final ssLegacy = 'ss://${_b64('aes-128-gcm:pass@192.0.2.12:8388')}#Legacy';
const hy2 = 'hy2://hy-pass@jp1.example:443?sni=jp1.example&obfs=salamander&obfs-password=ob&mport=20000-30000&insecure=1#%F0%9F%87%AF%F0%9F%87%B5%20Tokyo';
// Same protocol, no SNI at all: exercises tls.disable_sni end to end (real sing-box check).
const hy2SniOff = 'hy2://hy2-pass@jp2.example:443?sni=off&obfs=salamander&obfs-password=ob2#%F0%9F%87%AF%F0%9F%87%B5%20Osaka';
const tuic = 'tuic://11111111-2222-3333-4444-555555555555:tuic-pass@sg1.example:443?congestion_control=bbr&alpn=h3&sni=sg1.example#SG';
const anytls = 'anytls://any-pass@us1.example:443?sni=us1.example#US';
// v2rayN JSON link
final vmessJson = 'vmess://${_b64(jsonEncode({
  'v': '2', 'ps': 'VMess WS', 'add': 'tr1.example', 'port': '443', 'id': '11111111-2222-3333-4444-555555555555', 'aid': '0',
  'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': 'tr1.example', 'path': '/vm', 'tls': 'tls', 'sni': 'tr1.example',
}))}';

// vmess://uuid@host:port?… — the URI form some panels export instead of v2rayN JSON.
const vmessUri =
    'vmess://11111111-2222-3333-4444-555555555555@tr2.example:443?type=grpc&serviceName=vm&security=tls&sni=tr2.example&encryption=aes-128-gcm#TR%20gRPC';
final socksB64 = 'socks://${_b64('user:pass')}@192.0.2.40:1080#SOCKS%20v2rayN';
const socks5Plain = 'socks5://u2:p2@192.0.2.41:1081#SOCKS5';
const hysteria1 =
    'hysteria://hk1.example:443?protocol=udp&auth=hy1-pass&peer=hk1.example&upmbps=20&downmbps=100&obfs=xplus&obfsParam=hide&alpn=hysteria#HK%20Hy1';
const vlessQuic = 'vless://11111111-2222-3333-4444-555555555555@ca1.example:443?type=quic&security=tls&sni=ca1.example#CA%20QUIC';

final allLinks = [
  vlessReality, vlessWs, vlessWsVariant, vlessXhttp, trojanGrpc, ssSip002, ss2022, ssLegacy, hy2, hy2SniOff, tuic, anytls, vmessJson,
  vmessUri, socksB64, socks5Plain, hysteria1, vlessQuic,
];

// Servers sing-box cannot run: listed as unsupported, never in a config.
const wireguardLink = 'wireguard://cHJpdmF0ZWtleQ%3D%3D@203.0.113.5:51820?publickey=cHVibGlj&address=10.0.0.2%2F32#WG%20Home';
final ssrLink = 'ssr://${base64Url.encode(utf8.encode('203.0.113.6:8388:auth_aes128_md5:aes-256-cfb:tls1.2_ticket_auth:'
    '${base64Url.encode(utf8.encode('pw'))}/?remarks=${base64Url.encode(utf8.encode('SSR Old'))}'))}';
const vlessEncrypted =
    'vless://11111111-2222-3333-4444-555555555555@mx1.example:443?type=tcp&security=tls&sni=mx1.example&encryption=mlkem768x25519plus.native.0rtt.abc#MX%20PQ';
final unsupportedLinks = [wireguardLink, ssrLink, vlessEncrypted];

// Every Clash type and transport the parser knows, one of each.
const clashMore = '''
proxies:
  - {name: VM WS, type: vmess, server: vm1.example, port: 443, uuid: 11111111-2222-3333-4444-555555555555, alterId: 0, cipher: auto, tls: true, servername: vm1.example, network: ws, ws-opts: {path: /vmws, headers: {Host: cdn.vm1.example}, max-early-data: 2048}}
  - {name: TJ gRPC, type: trojan, server: tj1.example, port: 443, password: tj-pass, sni: tj1.example, network: grpc, grpc-opts: {grpc-service-name: tjsvc}}
  - {name: VL H2, type: vless, server: vl1.example, port: 443, uuid: 11111111-2222-3333-4444-555555555555, tls: true, servername: vl1.example, network: h2, h2-opts: {host: [vl1.example], path: /h2}}
  - {name: VL Upgrade, type: vless, server: vl2.example, port: 443, uuid: 11111111-2222-3333-4444-555555555555, tls: true, servername: vl2.example, network: ws, ws-opts: {path: /up, headers: {Host: vl2.example}, v2ray-http-upgrade: true}}
  - {name: TUIC, type: tuic, server: tu1.example, port: 443, uuid: 11111111-2222-3333-4444-555555555555, password: tu-pass, sni: tu1.example, alpn: [h3], congestion-controller: cubic, udp-relay-mode: native}
  - {name: AnyTLS, type: anytls, server: at1.example, port: 443, password: at-pass, sni: at1.example, client-fingerprint: chrome}
  - {name: Hy1, type: hysteria, server: hy1.example, port: 443, auth-str: hy-auth, up: 30 Mbps, down: 200 Mbps, sni: hy1.example, obfs: hide}
  - {name: Socks, type: socks5, server: 192.0.2.50, port: 1080, username: u, password: p}
  - {name: HTTP TLS, type: http, server: hp1.example, port: 443, username: u, password: p, tls: true, sni: hp1.example}
  - {name: SSH, type: ssh, server: 192.0.2.51, port: 22, username: root, password: ssh-pass}
  - {name: WG, type: wireguard, server: 203.0.113.7, port: 51820, private-key: cHJpdmF0ZQ==, public-key: cHVibGlj, ip: 10.0.0.3}
  - {name: VL PQ, type: vless, server: vl3.example, port: 443, uuid: 11111111-2222-3333-4444-555555555555, tls: true, encryption: mlkem768x25519plus.native.0rtt.abc}
  - {name: Direct, type: direct}
''';

// The Frankfurt server again, as mihomo would get it: must dedup with vlessReality.
const clashYaml = '''
mixed-port: 7890
proxies:
  - name: "🇩🇪 Frankfurt 01"
    type: vless
    server: de1.example
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: www.microsoft.com
    client-fingerprint: chrome
    reality-opts:
      public-key: Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw
      short-id: 6ba85179e30d4fc2
  - name: Clash only HY2
    type: hysteria2
    server: kz1.example
    port: 443
    password: pw
    ports: 20000-21000
    sni: kz1.example
  - name: SS obfs
    type: ss
    server: 192.0.2.20
    port: 8388
    cipher: chacha20-ietf-poly1305
    password: pw
    plugin: obfs
    plugin-opts: {mode: http, host: bing.com}
  - name: Unknown
    type: snell
    server: x.example
    port: 1
proxy-groups: []
''';

const singboxJson = '''
{"outbounds":[
  {"type":"selector","tag":"select","outbounds":["DE"]},
  {"type":"vless","tag":"🇩🇪 Frankfurt 01","server":"de1.example","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","flow":"xtls-rprx-vision",
   "tls":{"enabled":true,"server_name":"www.microsoft.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw","short_id":"6ba85179e30d4fc2"}}},
  {"type":"shadowsocks","tag":"via stls","server":"192.0.2.30","server_port":443,"method":"aes-128-gcm","password":"p","detour":"stls"},
  {"type":"direct","tag":"direct"}
]}
''';
