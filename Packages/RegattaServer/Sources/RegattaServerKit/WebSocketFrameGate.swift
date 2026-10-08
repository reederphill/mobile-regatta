import NIOCore
import NIOWebSocket

/// Ahead of the WebSocket frame decoder on `/service` (#145 review): reads each frame's header as the bytes arrive and
/// closes the connection (1009, message too big) as soon as a header claims a frame, or a fragmented message, larger
/// than `limit`, before its payload is buffered. The decoder's own limit is the service's cap for a signed-in
/// connection; this one starts small and the connection raises it once a session is signed in, so an unauthenticated
/// client can't make the server hold a 32 MiB frame. The bytes pass on unchanged.
final class WebSocketFrameGate: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    /// The largest frame, or message across its fragments, the client may send now.
    var limit: Int
    /// The header read so far (it may arrive split across reads).
    private var header: [UInt8] = []
    /// Payload bytes of the current frame still to pass.
    private var payloadLeft: UInt64 = 0
    /// The data message so far, across its fragments.
    private var messageBytes: UInt64 = 0
    private var refused = false

    init(limit: Int) { self.limit = limit }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !refused else { return }
        let buffer = unwrapInboundIn(data)
        var scan = buffer
        while scan.readableBytes > 0 {
            if payloadLeft > 0 {
                let skip = Int(min(UInt64(scan.readableBytes), payloadLeft))
                scan.moveReaderIndex(forwardBy: skip)
                payloadLeft -= UInt64(skip)
                continue
            }
            header.append(scan.readInteger(as: UInt8.self)!)
            guard let frame = Self.parse(header) else { continue }
            header = []
            let isData = frame.opcode < 0x8
            if isData {
                messageBytes = frame.opcode == 0 ? messageBytes &+ frame.length : frame.length
            }
            if frame.length > UInt64(limit) || (isData && messageBytes > UInt64(limit)) {
                return refuse(context)
            }
            if isData && frame.fin { messageBytes = 0 }
            payloadLeft = frame.length
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    private func refuse(_ context: ChannelHandlerContext) {
        refused = true
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .messageTooLarge)
        context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: data)))
            .whenComplete { _ in context.close(promise: nil) }
    }

    /// A complete frame header's FIN bit, opcode and payload length, or nil until all of it has arrived.
    static func parse(_ header: [UInt8]) -> (fin: Bool, opcode: UInt8, length: UInt64)? {
        guard header.count >= 2 else { return nil }
        let short = header[1] & 0x7F
        let extended = short == 126 ? 2 : short == 127 ? 8 : 0
        let mask = header[1] & 0x80 != 0 ? 4 : 0
        guard header.count >= 2 + extended + mask else { return nil }
        var length = UInt64(short)
        if extended > 0 {
            length = header[2..<(2 + extended)].reduce(0) { $0 << 8 | UInt64($1) }
        }
        return (header[0] & 0x80 != 0, header[0] & 0x0F, length)
    }
}
