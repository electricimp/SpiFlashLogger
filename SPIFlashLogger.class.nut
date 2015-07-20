class SPIFlashLogger {

    static version = [1,0,0];

    static SECTOR_SIZE = 4096;          // Size of sectors
    static SECTOR_META_SIZE = 6;        // Size of metadata at start of sectors
    static SECTOR_BODY_SIZE = 4090;     // Size of writeable memory / sector
    static CHUNK_SIZE = 256;            // Number of bytes we write / operation

    static OBJECT_MARKER = "\x00\xAA\xCC\x55";
    static OBJECT_MARKER_SIZE = 4;
    static OBJECT_HDR_SIZE = 7; // OBJECT_MARKER (4 bytes) + size (2 bytes) + crc (1 byte)
    static OBJECT_MIN_SIZE = 6; // OBJECT_MARKER (4 bytes) + size (2 bytes)

    static SECTOR_DIRTY = 0x00; // Flag for dirty sectors
    static SECTOR_CLEAN = 0xFF; // Flag for clean sectors

    _flash = null;      // hardware.spiflash or an object with an equivalent interface
    _serializer = null; // github.com/electricimp/serializer (or an object with an equivalent interface)

    _size = null;       // The size of the spiflash
    _start = null;      // First block to use for logging
    _end = null;        // Last block to use for logging
    _len = null;        // The length of the flash available (end-start)
    _sectors = 0;       // The number of sectors in _len
    _max_data = 0;      // The maximum data we can push at once
    _at_sec = 0;        // Current sector we're writing to
    _at_pos = 0;        // Current position we're writing to in the sector

    _map = null;        // Array of sector maps
    _enables = 0;       // Counting semaphore for _enable/_disable
    _next_sec_id = 1;   // The next sector we should write to

    constructor(serializer, start = null, end = null, flash = null) {
        // Set the flash and serializer references
        _flash = flash ? flash : hardware.spiflash;
        _serializer = serializer;

        // Get the size of the flash
        _enable();
        _size = _flash.size();
        _disable();

        // Set the start/end values
        _start = (start != null) ? start : 0;
        _end = (end != null) ? end : _size;

        // Validate the start/end values
        if (_start >= _size) throw "Invalid start parameter (start must be < size of SPI flash";
        if (_end <= _start) throw "Invalid end parameter (end must be > start)";
        if (_start % SECTOR_SIZE != 0) throw "Invalid start parameter (start must be at a sector boundary)";
        if (_end % SECTOR_SIZE != 0) throw "Invalid end parameter (end must be at a sector boundary)";

        // Set the other utility properties
        _len = _end - _start;
        _sectors = _len / SECTOR_SIZE;
        _max_data = _sectors * SECTOR_BODY_SIZE;

        // Can compress this by eight by using bits instead of bytes
        _map = blob(_sectors);

        // Initialise the values by reading the metadata
        _init();
    }

    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end, "sectors": _sectors, "sector_size": SECTOR_SIZE }
    }

    function write(object) {
        // Check of the object will fit
        local obj_len = _serializer.sizeof(object, OBJECT_MARKER);
        if (obj_len > _max_data) throw "Cannot store objects larger than alloted memory."

        // Serialize the object
        local object = _serializer.serialize(object, OBJECT_MARKER);

        _enable();

        // Write one sector at a time with the metadata attached
        local obj_pos = 0;
        local obj_remaining = obj_len;
        do {
            // How far are we from the end of the sector
            if (_at_pos < SECTOR_META_SIZE) _at_pos = SECTOR_META_SIZE;
            local sec_remaining = SECTOR_SIZE - _at_pos;
            if (obj_remaining < sec_remaining) sec_remaining = obj_remaining;

            // We are too close to the end of the sector, skip to the next sector
            if (sec_remaining < OBJECT_MIN_SIZE) {
                _at_sec = (_at_sec + 1) % _sectors;
                _at_pos = SECTOR_META_SIZE;
            }

            // Now write the data
            _write(object, _at_sec, _at_pos, obj_pos, sec_remaining);
            _map[_at_sec] = SECTOR_DIRTY;

            // Update the positions
            obj_pos += sec_remaining;
            obj_remaining -= sec_remaining;
            _at_pos += sec_remaining;
            if (_at_pos >= SECTOR_SIZE) {
                _at_sec = (_at_sec + 1) % _sectors;
                _at_pos = SECTOR_META_SIZE;
            }

        } while (obj_remaining > 0);

        _disable();
    }

    function readSync(callback) {
        local serialised_object = blob();

        _enable();
        for (local i = 0; i < _sectors; i++) {
            local sector = (_at_sec+i+1) % _sectors;

            // Ignore clean sectors
            if (_map[sector] != SECTOR_DIRTY) continue;

            // Read the whole body in. We could read in just the dirty chunks but for now this is easier
            local start = _start + (sector * SECTOR_SIZE);
            local data = _flash.read(start + SECTOR_META_SIZE, SECTOR_BODY_SIZE);
            local data_str = data.tostring();

            local find_pos = 0;
            while (find_pos < data.len()) {
                if (serialised_object.len() == 0) {
                    // We are at the start of a new object, so search for a header in the data
                    local header_loc = data_str.find(OBJECT_MARKER, find_pos);
                    if (header_loc != null) {

                        // Get the length of the object and make a blob to receive it
                        data.seek(header_loc + OBJECT_MARKER_SIZE);
                        local len = data.readn('w');
                        serialised_object = blob(OBJECT_HDR_SIZE + len);

                        // Now reenter the loop to receive the data into the new blob
                        data.seek(header_loc);
                        find_pos = header_loc;
                        continue;

                    } else {
                        // No object header found, so skip to the next sector
                        break;
                    }
                } else {
                    // Work out how much is required and available
                    local rem_in_data = data.len() - data.tell();
                    local rem_in_object = serialised_object.len() - serialised_object.tell();

                    // Copy only as much as is required and available
                    local rem_to_copy = (rem_in_data <= rem_in_object) ? rem_in_data : rem_in_object;
                    serialised_object.writeblob(data.readblob(rem_to_copy));

                    // If we have finished filling the serialised object then deserialise it
                    local rem_in_object = serialised_object.len() - serialised_object.tell();
                    if (rem_in_object == 0) {
                        try {
                            local object = _serializer.deserialize(serialised_object, OBJECT_MARKER);
                            callback(object);
                            find_pos += rem_to_copy;
                        } catch (e) {
                            /********** WHY IS THIS HERE **********/
                            server.error(e);
                            find_pos ++;
                        }
                        serialised_object.resize(0);
                    } else {
                        find_pos += rem_to_copy;
                    }

                    // If we have run out of data in this sector, move onto the next sector
                    local rem_in_data = data.len()  - data.tell();
                    if (rem_in_data == 0) {
                        break;
                    }
                }

            }
        }
        _disable();

    }

    function erase() {
        for (local sector = 0; sector < _sectors; sector++) {
            if (_map[sector] == SECTOR_DIRTY) {
                _erase(sector);
            }
        }
    }

    function _enable() {
        if (_enables == 0) {
            _flash.enable();
        }

        _enable += 1;
    }

    function _disable() {
        if (_enables == 0)  {
            _flash.disable();
        }
        _enables -= 1;
    }

    function _write(object, sector, pos, object_pos = 0, len = null) {
        if (len == null) len = object.len();

        // Prepare the new metadata
        local meta = blob(6);

        // Erase the sector(s) if it is dirty but not if we are appending
        local appending = (pos > SECTOR_META_SIZE);
        if (_map[sector] == SECTOR_DIRTY && !appending) {
            // Prepare the next sector
            _erase(sector, sector+1, true);
            // Write a new sector id
            meta.writen(_next_sec_id++, 'i');
        } else {
            // Make sure we have a valid sector id
            if (_getSectorMetadata(sector).id > 0) {
                meta.writen(0xFFFFFFFF, 'i');
            } else {
                meta.writen(_next_sec_id++, 'i');
            }
        }

        // Write the new usage map, changing only the bit in this write
        local chunk_map = 0xFFFF;
        local bit_start = math.floor(1.0 * pos / CHUNK_SIZE).tointeger();
        local bit_finish = math.ceil(1.0 * (pos+len) / CHUNK_SIZE).tointeger();
        for (local bit = bit_start; bit < bit_finish; bit++) {
            local mod = 1 << bit;
            chunk_map = chunk_map ^ mod;
        }
        meta.writen(chunk_map, 'w');

        // Write the metadata and the data
        local start = _start + (sector * SECTOR_SIZE);
        _enable();
        _flash.write(start, meta);
        _flash.write(start + pos, object, 0, object_pos, object_pos+len);
        _disable();

        return len;
    }

    function _getSectorMetadata(sector) {
        // NOTE: Should we skip clean sectors automatically?
        local start = _start + (sector * SECTOR_SIZE);
        local meta = _flash.read(start, SECTOR_META_SIZE);
        // Parse the meta data
        meta.seek(0);
        return { "id": meta.readn('i'), "map": meta.readn('w') };

    }

    function _init() {

        local best_id = 0;          // The highest id
        local best_sec = 0;         // The sector with the highest id
        local best_map = 0xFFFFF;   // The map of the sector with the highest id

        // Read all the metadata
        _enable();
        for (local sector = 0; sector < _sectors; sector++) {
            // Hunt for the highest id and its map
            local meta = _getSectorMetadata(sector);

            if (meta.id > 0) {
                if (meta.id > best_id) {
                    best_sec = sector;
                    best_id = meta.id;
                    best_map = meta.map;
                }
            } else {
                // This sector has no id, we are going to assume it is clean
                _map[sector] = SECTOR_CLEAN;
            }
        }
        _disable();

        _at_pos = 0;
        _at_sec = best_sec;
        _next_sec_id = best_id+1;
        for (local bit = 1; bit <= 16; bit++) {
            local mod = 1 << bit;
            _at_pos += (~best_map & mod) ? CHUNK_SIZE : 0;
        }

    }

    function _erase(start_sector = null, end_sector = null, preparing = false) {

        if (start_sector == null) {
            start_sector = 0;
            end_sector = _sectors;
        }
        if (end_sector == null) {
            end_sector = start_sector + 1;
        }
        if (start_sector < 0 || end_sector > _sectors) throw "Invalid format request";

        _enable();
        for (local sector = start_sector; sector < end_sector; sector++) {
            // Erase the requested sector
            _flash.erasesector(_start + (sector * SECTOR_SIZE));

            // Mark the sector as clean
            _map[sector] = SECTOR_CLEAN;

            // Move the pointer on to the next sector
            if (!preparing && sector == _at_sec) {
                _at_sec = (_at_sec + 1) % _sectors;
                _at_pos = SECTOR_META_SIZE;
            }
        }
        _disable();

    }
}
