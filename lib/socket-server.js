const express = require('express');
const http = require('http');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*", 
    methods: ["GET", "POST"]
  }
});

const streams = new Map();

io.on('connection', (socket) => {
  console.log('New client connected');

  socket.on('join_stream', ({ streamId, isStreamer }) => {
    console.log(`Client joining stream: ${streamId}, isStreamer: ${isStreamer}`);

    socket.join(streamId);
    socket.streamId = streamId;
    socket.isStreamer = isStreamer;

    if (!streams.has(streamId)) {
      streams.set(streamId, {
        streamer: isStreamer ? socket.id : null,
        viewers: new Set()
      });
    }

    const streamInfo = streams.get(streamId);
    if (isStreamer) {
      if (streamInfo.streamer) {
        socket.emit('error', 'Stream already has a broadcaster');
        return;
      }
      streamInfo.streamer = socket.id;
    } else {
      streamInfo.viewers.add(socket.id);
      if (streamInfo.streamer) {
        io.to(streamInfo.streamer).emit('viewer_joined', { viewerId: socket.id });
      }
    }
  });

  socket.on('offer', ({ streamId, viewerId, offer }) => {
    console.log(`Offer received for viewer: ${viewerId}`);
    io.to(viewerId).emit('offer', { type: offer.type, sdp: offer.sdp });
  });

  socket.on('answer', ({ streamId, answer }) => {
    console.log(`Answer received for stream: ${streamId}`);
    const streamInfo = streams.get(streamId);
    if (streamInfo && streamInfo.streamer) {
      io.to(streamInfo.streamer).emit('answer', {
        viewerId: socket.id,
        answer: { type: answer.type, sdp: answer.sdp }
      });
    }
  });

  socket.on('ice_candidate', ({ streamId, candidate }) => {
    console.log(`ICE candidate received for stream: ${streamId}`);
    socket.to(streamId).emit('ice_candidate', {
      viewerId: socket.id,
      candidate: {
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: parseInt(candidate.sdpMLineIndex, 10)
      }
    });
  });

  socket.on('disconnect', () => {
    for (const [streamId, streamInfo] of streams.entries()) {
      if (streamInfo.streamer === socket.id) {
        streamInfo.streamer = null;
      }
      streamInfo.viewers.delete(socket.id);

      if (!streamInfo.streamer && streamInfo.viewers.size === 0) {
        streams.delete(streamId);
      }
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Socket.IO server running on port ${PORT}`);
});