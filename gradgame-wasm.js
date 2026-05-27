(async () => {
    const wasmPath = '.build/wasm32-unknown-wasip1/debug/GradGame.wasm';
    const result = document.getElementById('wasm-add-result');
    let wasmExports = null;

    function writeUint32(memory, pointer, value) {
        new DataView(memory.buffer).setUint32(pointer, value, true);
    }

    const wasiSnapshotPreview1 = {
        args_get: () => 0,
        args_sizes_get: (argc, argvBufSize) => {
            if (!wasmExports?.memory) return 0;
            writeUint32(wasmExports.memory, argc, 0);
            writeUint32(wasmExports.memory, argvBufSize, 0);
            return 0;
        },
        environ_get: () => 0,
        environ_sizes_get: (count, bufSize) => {
            if (!wasmExports?.memory) return 0;
            writeUint32(wasmExports.memory, count, 0);
            writeUint32(wasmExports.memory, bufSize, 0);
            return 0;
        },
        fd_close: () => 0,
        fd_fdstat_get: () => 0,
        fd_prestat_get: () => 8,
        fd_prestat_dir_name: () => 8,
        fd_read: () => 0,
        fd_seek: () => 0,
        fd_write: () => 0,
        path_open: () => 8,
        proc_exit: (code) => {
            throw new Error(`WASI proc_exit(${code})`);
        },
        random_get: (buffer, length) => {
            if (!wasmExports?.memory) return 0;
            crypto.getRandomValues(new Uint8Array(wasmExports.memory.buffer, buffer, length));
            return 0;
        },
    };

    try {
        const response = await fetch(wasmPath);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }

        const imports = { wasi_snapshot_preview1: wasiSnapshotPreview1 };
        const { instance } = await WebAssembly.instantiateStreaming(response, imports);

        wasmExports = instance.exports;
        window.gradGameWasm = wasmExports;

        const value = wasmExports.add(2, 3);
        result.textContent = `Swift add(2, 3) = ${value}`;
        result.dataset.status = value === 5 ? 'pass' : 'fail';
    } catch (error) {
        result.textContent = `Swift Wasm test failed: ${error.message}`;
        result.dataset.status = 'fail';
        console.error(error);
    }
})();
