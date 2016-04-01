gelf
====
Implementation of [Graylog Extended Logging Format](http://docs.graylog.org/en/latest/pages/gelf.html) for `std.experimental.logger`.

##  Features
- Small and flexible API
- `GrayLogger` does not throw exceptions while it is sending a message
- UDP, TCP, and HTTP transports are supproted

## Examples

### UDP
```D
Compress c; // `null` value is for no compression
// c = new Compress;
// c = new Compress(HeaderFormat.gzip);
auto socket = new UdpSocket();
socket.connect(new InternetAddress("192.168.59.103", 12201));
// The last param is UDP chunk size. This is optional paramter with default value equals to 8192
sharedLog = new UdpGrayLogger(socket, c, "YourServiceName", LogLevel.all, 4096);

error("===== Error Information =====");
```

### TCP
```D
import std.typecons: Yes, No;
auto socket = new TcpSocket();
socket.connect(new InternetAddress("192.168.59.103", 12201));
// Defualt value for nullDelimeter is `Yes`.
// Newline delimiter would be used if nullDelimeter is `false`/`No`.
sharedLog = new TcpGrayLogger(socket, "YourServiceName", LogLevel.all, Yes.nullDelimeter);

error("===== Error Information =====");
```

### HTTP
```D
import std.net.curl: HTTP;
Compress c; // `null` value is for no compression
// c = new Compress;
// c = new Compress(HeaderFormat.gzip);
sharedLog = new HttpGrayLogger(HTTP("192.168.59.103:12201/gelf"), c, "YourServiceName", LogLevel.all);

error("===== Error Information =====");
```

