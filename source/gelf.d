
import std.socket;
import std.experimental.logger.core;
import std.range.primitives;
import std.format : formattedWrite;
import std.datetime : Date, DateTime, SysTime, UTC;
import std.concurrency : Tid;
import std.zlib: Compress;
import core.stdc.errno: errno, EINTR;


import std.stdio, std.array, std.algorithm;

GrayLogger grayLogger(UdpSocket socket, Compress compress, string host, LogLevel v, int chunk = 8192) @safe
{
	return new UdpGrayLogger(socket, compress, host, v, chunk);
}

GrayLogger grayLogger(TcpSocket socket, Compress compress, string host, LogLevel v) @safe
{
	return new TcpGrayLogger(socket, compress, host, v);
}

//class HttpGrayLogger : GrayLogger
//{
//	this(TcpSocket socket,  Compress compress, string host, LogLevel v) @safe
//	{
//		super(socket, compress, host, v);
//	}
//}

class TcpGrayLogger : GrayLogger
{
	this(TcpSocket socket,  Compress compress, string host, LogLevel v) @safe
	{
		super(socket, compress, host, v);
	}

	override protected void writeLogMsg(ref LogEntry payload)
	{
		if(!socket.isAlive)
		{
 			// The socket is dead.
			// Do nothing
			return;
		}
		auto data = messageData(payload);
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

debug import std.stdio;

class UdpGrayLogger : GrayLogger
{
	private ubyte[] _chunk;
	import std.random;
	import std.datetime;

	Mt19937 gen;

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

	private bool send(const(void)[] data) @safe
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
		auto data = messageData(payload);
		debug
		{
			writeln("Log msg: ", payload.msg);
		}
		if(data.length <= _chunk.length)
		{
			// send all data as single datagram
			send(data).writeln;
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
			_chunk[11] = cast(ubyte) chs.length;
			foreach(i, ch; chs.enumerate)
			{
				ulong[1] id = void;
				id[0] = uniform!ulong(gen);
				//Endianness does not matter
				_chunk[2..10] = cast(ubyte[]) id;
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
		debug
		{
			writeln("udp: sended!");
		}
	}
}

abstract class GrayLogger : Logger
{
	enum string gelfVersion = "1.1";

	private Socket _socket;
	private string _host;
	private Compress _compress;
	private immutable string _msgStart;

	this(Socket socket, Compress compress, string host, LogLevel v) @safe
	{
		if(!socket.blocking)
			throw new SocketException("GrayLogger: socket must be blocking.");
		_socket = socket;
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

	final const(void)[] messageData(ref LogEntry payload) @trusted
	out(result)
	{
		assert(result.length);
	}
	body
	{
		import std.array: appender;
		auto app = appender!(const(ubyte)[])();
		app.reserve(1024);
		if(_compress)
		{
			formatMessage( (str) { app.put(cast(const(ubyte)[]) _compress.compress(str)); }, payload);
			app.put(cast(const(ubyte)[]) _compress.flush);
		}
		else
		{
			formatMessage( (str) { app.put(cast(const(ubyte)[]) str); }, payload);
			debug
			{
				writeln(cast(string)app.data);
			}
		}
		return cast(typeof(return)) app.data;
	}

	final @property @safe pure nothrow @nogc:
	
	string host()
	{
		return _host;
	}

	Socket socket()
	{
		return _socket;
	}
}
