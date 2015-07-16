/*
 * To Do: Add callbacks to allow the _at_pos to be read and write from nv. 
 *        It should be read at init() and written at write()
 */

//==============================================================================
class SPIFlashLogger {
    
    _flash = null;
    _size = null;
    _start = null;
    _end = null;
    _len = null;
    _sectors = 0;
    _max_data = 0;
    _at_sec = 0;
    _at_pos = 0;
    _map = null;
    _enables = 0;
    _next_sec_id = 1;
    
    static version = [0,1,0];
    
    static SECTOR_SIZE = 4096;
    static SECTOR_META_SIZE = 6;
    static SECTOR_BODY_SIZE = 4090;
    static CHUNK_SIZE = 256;
    
    static OBJECT_MARKER = "\x00\xAA\xCC\x55";
    static OBJECT_MARKER_SIZE = 4;
    static OBJECT_HDR_SIZE = 7; // OBJECT_MARKER (4 bytes) + size (2 bytes) + crc (1 byte)
    static OBJECT_MIN_SIZE = 6; // OBJECT_MARKER (4 bytes) + size (2 bytes)

    static SECTOR_DIRTY = 0x00;
    static SECTOR_CLEAN = 0xFF;
    
    //--------------------------------------------------------------------------
    constructor(start = null, end = null, flash = null) {
        
        if (!("Serializer" in getroottable())) throw "Serializer class must be defined";
        
        _flash = flash ? flash : hardware.spiflash;

        _enable();
        _size = _flash.size();
        _disable();
        
        if (start == null) _start = 0;
        else if (start < _size) _start = start;
        else throw "Invalid start value";
        if (_start % SECTOR_SIZE != 0) throw "start must be at a sector boundary";
        
        if (end == null) _end = _size;
        else if (end > _start) _end = end;
        else throw "Invalid end value";
        if (_end % SECTOR_SIZE != 0) throw "end must be at a sector boundary";
        
        _len = _end - _start;
        _sectors = _len / SECTOR_SIZE;
        _max_data = _sectors * SECTOR_BODY_SIZE;
        _map = blob(_sectors); // Can compress this by eight by using bits instead of bytes
        
        // Initialise the values by reading the metadata
        _init();
    }
    
    //--------------------------------------------------------------------------
    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end, "sectors": _sectors, "sector_size": SECTOR_SIZE }
    }
    
    //--------------------------------------------------------------------------
    function write(object) {
        
        // Serialise the object
        local object = Serializer.serialize(object, OBJECT_MARKER);
        local obj_len = object.len();
        assert(obj_len < _max_data);

        _enable();
        
        // Write one sector at a time with the metadata attached
        local obj_pos = 0, obj_remaining = obj_len;
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
    
    //--------------------------------------------------------------------------
    function readSync(callback) {
        
        local serialised_object = blob();

        _enable();
        for (local i = 0; i < _sectors; i++) {
            local sector = (_at_sec+i+1) % _sectors;
            if (_map[sector] == SECTOR_DIRTY) {

                // Read the whole body in. We could read in just the dirty chunks but for now this is easier
                local start = _start + (sector * SECTOR_SIZE);
                local data = _flash.read(start + SECTOR_META_SIZE, SECTOR_BODY_SIZE);
                local data_str = data.tostring();

                local find_pos = 0;
                while (find_pos < data.len()) {
                    if (serialised_object.len() == 0) {
                        
                        // We are at the start of a new object, so search for a header in the data
                        // server.log(format("Searching for header from sec %d pos %d", sector, find_pos));
                        local header_loc = data_str.find(OBJECT_MARKER, find_pos);
                        if (header_loc != null) {

                            
                            // Get the length of the object and make a blob to receive it
                            data.seek(header_loc + OBJECT_MARKER_SIZE);
                            local len = data.readn('w');
                            serialised_object = blob(OBJECT_HDR_SIZE + len);
                            
                            // server.log(format("Found a header at sec %d pos %d len %d", sector, header_loc, len));
                            
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
                        local rem_in_data = data.len()  - data.tell();
                        local rem_in_object = serialised_object.len() - serialised_object.tell();
                        
                        // Copy only as much as is required and available
                        local rem_to_copy = (rem_in_data <= rem_in_object) ? rem_in_data : rem_in_object;
                        // server.log(format("rem_in_data = %d, rem_in_object = %d => rem_to_copy = %d", rem_in_data, rem_in_object, rem_to_copy))
                        serialised_object.writeblob(data.readblob(rem_to_copy));

                        // If we have finished filling the serialised object then deserialise it
                        local rem_in_object = serialised_object.len() - serialised_object.tell();
                        if (rem_in_object == 0) {
                            try {
                                local object = Serializer.deserialize(serialised_object, OBJECT_MARKER);
                                callback(object);
                                find_pos += rem_to_copy;
                                // server.log("After deserialise, search from: " + find_pos);
                            } catch (e) {
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
        }
        _disable();

    }
    
    //--------------------------------------------------------------------------
    function erase() {
        for (local sector = 0; sector < _sectors; sector++) {
            if (_map[sector] == SECTOR_DIRTY) {
                erase(sector);
            }
        }
    }
    
    //--------------------------------------------------------------------------
    function _enable() {
        if (_enables++ == 0) {
            _flash.enable();
        }
    }    
    
    //--------------------------------------------------------------------------
    function _disable() {
        if (--_enables == 0)  {
            _flash.disable();
        }
    }    
    
    //--------------------------------------------------------------------------
    function _write(object, sector, pos, object_pos = 0, len = null) {
        
        if (len == null) len = object.len();

        // Prepare the new metadata
        local meta = blob(6);

        // Erase the sector(s) if it is dirty but not if we are appending
        local appending = (pos > SECTOR_META_SIZE);
        if (_map[sector] == SECTOR_DIRTY && !appending) {
            // Prepare the next sector
            erase(sector, sector+1, true);
            // Write a new sector id
            meta.writen(_next_sec_id++, 'i');
        } else {
            // Make sure we have a valid sector id
            if (_metadata(sector).id > 0) {
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
        // server.log(format("Writing to sec %d pos %d to %d and metadata 0x%04x", sector, pos, pos+len, chunk_map));
        _enable();
        _flash.write(start, meta);
        _flash.write(start + pos, object, 0, object_pos, object_pos+len);
        _disable();
        
        return len;
    }
    
    //--------------------------------------------------------------------------
    function _metadata(sector) {
        // NOTE: Should we skip clean sectors automatically?
        // server.log("Reading meta from sector: " + sector);
        local start = _start + (sector * SECTOR_SIZE);
        local meta = _flash.read(start, SECTOR_META_SIZE);
        // Parse the meta data 
        meta.seek(0);
        return { "id": meta.readn('i'), "map": meta.readn('w') };
        
    }
    
    //--------------------------------------------------------------------------
    function _init() {
        
        local best_id = 0, best_sec = 0, best_map = 0xFFFFF;
        
        // Read all the metadata
        _enable();
        for (local sector = 0; sector < _sectors; sector++) {
            // Hunt for the highest id and its map
            local meta = _metadata(sector);
            if (meta.id > 0) {
                if (meta.id > best_id) {
                    best_sec = sector;
                    best_id = meta.id;
                    best_map = meta.map;
                }
                // server.log(format("Sector %d [id: %d] => 0x%04x", sector, meta.id, meta.map));
            } else {
                // This sector has no id, we are going to assume it is clean
                _map[sector] = SECTOR_CLEAN;
            }
        }
        _disable();
        
        // We should have the answers we are seeking now
        _at_pos = 0;
        _at_sec = best_sec;
        _next_sec_id = best_id+1;
        for (local bit = 1; bit <= 16; bit++) {
            local mod = 1 << bit;
            _at_pos += (~best_map & mod) ? CHUNK_SIZE : 0;
        }
        // server.log(format("Initial sector %d [next_id: %d], pos %d", _at_sec, _next_sec_id, _at_pos));
        
    }
    
    //--------------------------------------------------------------------------
    function _erase(start_sector = null, end_sector = null, preparing = false) {
        
        if (start_sector == null) {
            start_sector = 0;
            end_sector = _sectors;
        }
        if (end_sector == null) {
            end_sector = start_sector + 1;
        } 
        if (start_sector < 0 || end_sector > _sectors) throw "Invalid format request";

        /*
        if (start_sector +1 == end_sector) {
            server.log(format("Erasing flash sectors %d", start_sector));
        } else {
            server.log(format("Erasing flash from sectors %d to %d", start_sector, end_sector));
        }
        */
        
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

