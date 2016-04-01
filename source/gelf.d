/++
Implementation of Graylog Extended Logging Format for `std.experimental.logger`.
+/
module gelf;

//version = gelf_test_udp;
//version = gelf_test_tcp;
//version = gelf_test_http;

/// UDP
version(gelf_test_udp)
unittest
{
	import std.format: format;
	foreach(i, c; [Compress.init, new Compress, new Compress(HeaderFormat.gzip)])
	{
		auto socket = new UdpSocket();
		socket.connect(new InternetAddress("192.168.59.103", 12201));
		auto logger = new UdpGrayLogger(socket, null, "UDP%s".format(i), LogLevel.all, 512);
		logger.errorf("===== UDP #%s.0 =====", i);
		logger.errorf("===== UDP #%s.1 =====", i);
		logger.errorf("========== UDP #%s.3 ==========\n%s", i,
			"Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed vitae nisl scelerisque,
			vestibulum arcu quis, rhoncus leo. Nunc ullamcorper nibh vitae nisl viverra dignissim.
			Etiam dictum tincidunt commodo. Morbi faucibus et ipsum in hendrerit. Phasellus rutrum,
			lacus at auctor tempor, metus nisl suscipit nisi, elementum molestie quam enim nec erat.
			Sed cursus libero felis, in pulvinar neque molestie eget. Praesent pulvinar est vitae sem
			pulvinar, pharetra dignissim velit condimentum.

			Vestibulum laoreet lorem eu dui ornare, ac congue enim consectetur.
			Morbi tincidunt, turpis et egestas sodales, erat velit suscipit felis,
			quis porttitor nulla turpis ut odio. Fusce in faucibus felis, ac feugiat mauris.
			Nullam vel sagittis mi. Nullam eu turpis ullamcorper, porta odio sit amet, dictum lorem.
			Nunc dictum in sem vel pharetra. In consectetur posuere massa, sed convallis felis tempus quis.
			Maecenas eleifend aliquam lectus pretium aliquam. Morbi viverra dui tortor,
			vel laoreet libero accumsan sed. Quisque congue erat quis nisl sed.");
	}
}

/// TCP
version(gelf_test_tcp)
unittest
{
	auto socket = new TcpSocket();
	socket.connect(new InternetAddress("192.168.59.103", 12202));
	auto logger = new TcpGrayLogger(socket, "TCP", LogLevel.all);
	logger.error("===== TCP.0 =====");
	logger.error("===== TCP.1 =====");
	logger.error("===== TCP.2 =====");
}

/// HTTP
version(gelf_test_http)
unittest
{
	import std.format: format;
	import std.net.curl;
	foreach(i, c; [Compress.init, new Compress, new Compress(HeaderFormat.gzip)])
	{
		auto logger = new HttpGrayLogger(HTTP("192.168.59.103:12204/gelf"), c, "HTTP%s".format(i), LogLevel.all);
		logger.errorf("===== HTTP #%s =====", i);
	}
}

unittest
{
	void t_udp()
	{
		Compress c; //`null` value for no compression
		// c = new Compress;
		// c = new Compress(HeaderFormat.gzip);
		auto socket = new UdpSocket();
		socket.connect(new InternetAddress("192.168.59.103", 12201));
		// The last param is UDP chunk size. This is optional paramter with default value equals to 8192
		sharedLog = new UdpGrayLogger(socket, c, "YourServiceName", LogLevel.all, 4096);
		error("===== Error Information =====");
	}

	void t_tcp()
	{
		import std.typecons: Yes, No;
		auto socket = new TcpSocket();
		socket.connect(new InternetAddress("192.168.59.103", 12201));
		/+Defualt value for nullDelimeter is `Yes`. Newline delimiter would be used if nullDelimeter is `false`/`No`.+/
		sharedLog = new TcpGrayLogger(socket, "YourServiceName", LogLevel.all, Yes.nullDelimeter);
		error("===== Error Information =====");
	}

	void t_http()
	{
		import std.net.curl: HTTP;
		Compress c; //`null` value for no compression
		// c = new Compress;
		// c = new Compress(HeaderFormat.gzip);
		sharedLog = new HttpGrayLogger(HTTP("192.168.59.103:12204/gelf"), c, "YourServiceName", LogLevel.all);
		error("===== Error Information =====");
	}
}

public import std.experimental.logger.core;

import std.socket;
import std.format : formattedWrite;
import std.datetime : Date, DateTime, SysTime, UTC;
import std.concurrency : Tid;
import std.zlib: Compress, HeaderFormat;
import core.stdc.errno: errno, EINTR;

/++
HTTP Graylog Logger
+/
class HttpGrayLogger : GrayLogger
{
	import std.net.curl;

	protected HTTP _http;

	/++
	Params:
		http = HTTP configuration. See `std.net.curl`.
		compress = compress algorithm. Sets `null` or `Compress.init` to send messages without compression.
		host = local service name
		v = log level
		chunk = maximal chunk size (size of UDP datagram)
	+/
	this(HTTP http, Compress compress, string host, LogLevel v) @trusted
	{
		_http = http;
		super(compress, host, v);
	}

	override protected void writeLogMsg(ref LogEntry payload) @trusted
	{
		fillAppender(payload);
		auto msg = _dataAppender.data;
		scope(exit) clearAppender;
		http.contentLength = msg.length;
		http.onSend =
			(void[] data)
			{
				import std.algorithm.comparison: min;
				immutable len = min(data.length, msg.length);
				if (len)
				{
					data[0..len] = msg[0..len];
					msg = msg[len .. $];
				}
				return len;
			};
		import std.typecons: No;
		http.perform(No.throwOnError);
	}

	final HTTP http() @property nothrow
	{
		return _http;
	}
}

/++
TCP Graylog Logger
+/
class TcpGrayLogger : SocketGrayLogger
{
	import std.typecons: Flag, Yes;

	private immutable string delim;

	/++
	Graylog TCP connection does not support compression.
	Params:
		socket = remote blocking TCP socket
		host = local service name
		v = log level
		useNull = Use null byte as frame delimiter? Otherwise newline delimiter is used.
	+/
	this(TcpSocket socket, string host, LogLevel v, Flag!"nullDelimeter" useNull = Yes.nullDelimeter) @safe
	{
		delim = useNull ? "\0" : "\n";
		super(socket, null, host, v);
	}

	override protected void writeLogMsg(ref LogEntry payload) @trusted
	{
		if(!socket.isAlive)
		{
 			// The socket is dead.
			// Do nothing
			return;
		}
		fillAppender(payload);
		scope(exit) clearAppender;
		_dataAppender.put(cast(ubyte[])delim);
		auto data = _dataAppender.data;
		do
		{
			immutable status = socket.send(data);
			if(status == Socket.ERROR)
			{
				if(errno == EINTR)
				{
					// Probably the GC interupted the process.
					// Try again
					continue;
				}
				// Failed to send data
				// Do nothing
				break;
			}
			data = data[status..$];
		}
		while(data.length);
	}
}

/++
UDP Graylog Logger
+/
class UdpGrayLogger : SocketGrayLogger
{
	protected ubyte[] _chunk;
	import std.random;
	import std.datetime;

	Mt19937 gen;

	/++
	Params:
		socket = remote blocking UDP socket
		compress = compress algorithm. Set `null` or `Compress.init` to send messages without compression.
		host = local service name
		v = log level
		chunk = maximal chunk size (size of UDP datagram)
	+/
	this(UdpSocket socket, Compress compress, string host, LogLevel v, int chunk = 8192) @safe
	{
		super(socket, compress, host, v);
		if(chunk < 512)
			throw new Exception("chunk must be greater or equal to 512");
		_chunk = new ubyte[chunk];
		_chunk[0] = 0x1e;
		_chunk[1] = 0x0f;
		gen = typeof(gen)(cast(uint)(MonoTime.currTime.ticks ^ (uniform!size_t * hashOf(host))));
	}

	protected bool send(const(void)[] data) @safe
	{
		for(;;)
		{
			immutable status = socket.send(data);
			if(status == Socket.ERROR)
			{
				if(errno == EINTR)
				{
					// Probably the GC interupted the process.
					// Try again
					continue;
				}
				// Failed to send the datagram.
				// Do nothing
				return false;
			}
			return status == data.length;
		}
	}

	override protected void writeLogMsg(ref LogEntry payload) @trusted
	{
		if(!socket.isAlive)
		{
			// The socket is dead.
			// Do nothing
			return;
		}
		fillAppender(payload);
		auto data = _dataAppender.data;
		scope(exit) clearAppender;
		if(data.length <= _chunk.length)
		{
			// send all data as single datagram
			send(data);
		}
		else
		{
			// send all data by chunks
			import std.range: chunks, enumerate;
			auto chs = (cast(ubyte[])data).chunks(_chunk.length - 12);
			immutable len = chs.length;
			if(len > 128)
			{
				// ignore huge msg
				return;
			}
			ulong[1] id = void;
			id[0] = uniform!ulong(gen);
			_chunk[2..10] = cast(ubyte[]) id;
			_chunk[11] = cast(ubyte) len;
			foreach(i, ch; chs.enumerate)
			{
				//Endianness does not matter
				_chunk[10] = cast(ubyte) i;
				immutable datagramLength = 12 + ch.length;
				_chunk[12 .. datagramLength] = ch[];
				immutable success = send(_chunk[0 .. datagramLength]);
				if(!success)
				{
					return;
				}
			}
		}
	}
}

/++
Abstract Socket Graylog Logger
+/
abstract class SocketGrayLogger : GrayLogger
{
	protected Socket _socket;

	/++
	Params:
		socket = remote blocking socket
		compress = compress algorithm. Set `null` or `Compress.init` to send messages without compression.
		host = local service name
		v = log level
	+/
	this(Socket socket, Compress compress, string host, LogLevel v) @safe
	{
		if(!socket.blocking)
			throw new SocketException("SocketGrayLogger: socket must be blocking.");
		_socket = socket;
		super(compress, host, v);
	}

	final Socket socket() @property @safe pure nothrow @nogc
	{
		return _socket;
	}
}

/++
Abstract Graylog Logger
+/
abstract class GrayLogger : Logger
{
	enum string gelfVersion = "1.1";
	import std.array: appender, Appender;

	protected string _host;
	protected Compress _compress;
	protected immutable string _msgStart;
	protected Appender!(ubyte[]) _dataAppender;

	/++
	Params:
		compress = compress algorithm. Set `null` or `Compress.init` to send messages without compression.
		host = local service name
		v = log level
	+/
	this(Compress compress, string host, LogLevel v) @safe
	{
		_dataAppender = appender!(ubyte[]);
		_host = host;
		_compress = compress;
		_msgStart = `{"version":"` ~ gelfVersion ~ `","host":"` ~ host ~ `","short_message":`;
		super(v);
	}

	protected void formatMessage(scope void delegate(const(char)[]) sink, ref LogEntry payload) @trusted
	{
		import std.format;
		FormatSpec!char fmt;

		sink(_msgStart);
		sink.formatElement(payload.msg, fmt);

		sink(`,"timestamp":`);
		//auto time = payload.timestamp;
		auto time = payload.timestamp.toUTC;
		sink.formatValue(time.toUnixTime, fmt);
		if(immutable msc = time.fracSecs.total!"msecs")
		{
			sink(".");
			sink.formatValue(msc, fmt);
		}

		sink(`,"level":`);
		uint level = void;
		final switch(payload.logLevel) with(LogLevel)
		{
			case all:     level = 7; break; // Debug: debug-level messages
			case trace:   level = 6; break; // Informational: informational messages
			case info:    level = 5; break; // Notice: normal but significant condition
			case warning: level = 4; break; // Warning: warning conditions
			case error:   level = 3; break; // Error: error conditions
			case critical:level = 2; break; // Critical: critical conditions
			case fatal:   level = 1; break; // Alert: action must be taken immediately
			case off:     level = 0; break; // Emergency: system is unusable
		}
		sink.formatValue(level, fmt);

		sink(`,"line":`);
		sink.formatValue(payload.line, fmt);
		sink(`,"file":"`);
		sink.formatValue(payload.file, fmt);
		sink(`","_func_name":"`);
		sink(payload.funcName);
		sink(`","_pretty_func_name":"`);
		sink(payload.prettyFuncName);
		sink(`","_module_name":"`);
		sink(payload.moduleName);
		sink(`"}`);
	}

	final void fillAppender(ref LogEntry payload) @trusted
	{
		if(_compress)
		{
			formatMessage( (str) { _dataAppender.put(cast(const(ubyte)[]) _compress.compress(str)); }, payload);
			_dataAppender.put(cast(const(ubyte)[]) _compress.flush);
		}
		else
		{
			formatMessage( (str) { _dataAppender.put(cast(const(ubyte)[]) str); }, payload);
		}
	}

	final void clearAppender()
	{
		enum ml = 8192;
		_dataAppender.clear;
		if(_dataAppender.capacity > ml)
		{
			_dataAppender.shrinkTo(ml);
		}
	}

	final string host() @property @safe pure nothrow @nogc
	{
		return _host;
	}
}
