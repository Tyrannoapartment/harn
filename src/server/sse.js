/**
 * SSE (Server-Sent Events) broadcast manager.
 * Replaces SSE functionality from harn_server.py
 */

/** Create an SSE manager. */
export function createSSEManager() {
  const clients = new Set();

  function addClient(res) {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });
    res.write('data: {"type":"connected"}\n\n');
    clients.add(res);
    res.on('close', () => clients.delete(res));
  }

  function broadcast(event, data) {
    const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const client of clients) {
      try { client.write(payload); } catch { clients.delete(client); }
    }
  }

  function broadcastLog(text) {
    broadcast('log', { text, timestamp: Date.now() });
  }

  /** Broadcast run status change (running/waiting/completed). */
  function broadcastStatus(status) {
    broadcast('status', { ...status, timestamp: Date.now() });
  }

  /** Broadcast sprint progress update. */
  function broadcastProgress(progress) {
    broadcast('progress', { ...progress, timestamp: Date.now() });
  }

  /** Broadcast a chunk of streaming AI output. */
  function broadcastAIChunk(chunk, meta = {}) {
    broadcast('ai_chunk', { chunk, ...meta, timestamp: Date.now() });
  }

  /** Broadcast a phase result report (spec, contract, qa-report, etc.). */
  function broadcastResult(text, meta = {}) {
    broadcast('result', { text, ...meta, timestamp: Date.now() });
  }

  function clientCount() {
    return clients.size;
  }

  return { addClient, broadcast, broadcastLog, broadcastStatus, broadcastProgress, broadcastAIChunk, broadcastResult, clientCount };
}
