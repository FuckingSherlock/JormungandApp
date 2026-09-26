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

final allLinks = [
  vlessReality, vlessWs, vlessWsVariant, vlessXhttp, trojanGrpc, ssSip002, ss2022, ssLegacy, hy2, hy2SniOff, tuic, anytls, vmessJson,
];

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
