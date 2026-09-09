// Owns operation identity, log offsets, decoding, and polling lifecycle.
function createOperationMonitor({ intervalMs, onSnapshot, onDisconnect, onReconnect, onMismatch }) {
  let operationId = '';
  let kind = '';
  let offset = 0;
  let decoder = null;
  let timer = null;
  let fetching = false;
  let generation = 0;
  let disconnected = false;
  let disconnectedAt = 0;

  function stop() {
    generation++;
    clearTimeout(timer);
    timer = null;
    fetching = false;
  }

  function consume(data, expectedGeneration) {
    if (expectedGeneration !== generation) return false;
    if (data.operation_id !== operationId || data.kind !== kind) {
      stop();
      onMismatch(data);
      return false;
    }
    if (disconnected) {
      disconnected = false;
      disconnectedAt = 0;
      onReconnect();
    }
    const finished = data.status === 'done' || data.status === 'failed';
    let chunk = '';
    try {
      chunk = decodeLogChunk(decoder, data.log || '', finished);
    } catch (error) {
      chunk = '\n[Could not decode log chunk]';
    }
    if (typeof data.offset === 'number') offset = data.offset;
    onSnapshot(data, chunk);
    if (finished) stop();
    return !finished;
  }

  function schedule(expectedGeneration, delay) {
    clearTimeout(timer);
    timer = setTimeout(() => poll(expectedGeneration), delay);
  }

  function poll(expectedGeneration) {
    if (expectedGeneration !== generation || fetching) return;
    fetching = true;
    const requestedOffset = offset;
    fetchWithTimeout(fetchJSON, '/cgi-bin/get_update_log?offset=' + requestedOffset, 8000)
      .then((data) => {
        if (expectedGeneration !== generation || requestedOffset !== offset) return;
        if (consume(data, expectedGeneration)) schedule(expectedGeneration, intervalMs);
      })
      .catch(() => {
        if (expectedGeneration !== generation) return;
        if (!disconnected) {
          disconnected = true;
          disconnectedAt = Date.now();
        }
        onDisconnect(Date.now() - disconnectedAt);
        schedule(expectedGeneration, intervalMs);
      })
      .finally(() => {
        if (expectedGeneration === generation) fetching = false;
      });
  }

  function start({ id, expectedKind, initial = null, immediate = true }) {
    stop();
    operationId = id;
    kind = expectedKind;
    offset = 0;
    decoder = new TextDecoder('utf-8');
    disconnected = false;
    disconnectedAt = 0;
    const expectedGeneration = generation;
    if (initial) {
      if (!consume(initial, expectedGeneration)) return;
      offset = typeof initial.offset === 'number' ? initial.offset : 0;
    }
    schedule(expectedGeneration, immediate ? 0 : intervalMs);
  }

  function acknowledge(id = operationId) {
    if (!/^[a-f0-9]{32}$/.test(id || '')) return Promise.resolve(false);
    return fetchJSON('/cgi-bin/get_update_log', {
      method: 'POST',
      body: new URLSearchParams({ operation_id: id }),
    }).then((data) => data.ok === true).catch(() => false);
  }

  return { start, stop, acknowledge };
}
