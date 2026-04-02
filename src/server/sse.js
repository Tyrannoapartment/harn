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

  function broadcastStatus(status) {
    broadcast('status', status);
  }

  function clientCount() {
    return clients.size;
  }

  return { addClient, broadcast, broadcastLog, broadcastStatus, clientCount };
}
