// Copyright (c) 2015-2016 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

// Using `const`s instead of `static`s for performance
const SPIFLASHLOGGER_SECTOR_SIZE = 4096;        // Size of sectors
const SPIFLASHLOGGER_SECTOR_META_SIZE = 6;      // Size of metadata at start of sectors
const SPIFLASHLOGGER_SECTOR_BODY_SIZE = 4090;   // Size of writeable memory / sector
const SPIFLASHLOGGER_CHUNK_SIZE = 256;          // Number of bytes we write / operation

const SPIFLASHLOGGER_OBJECT_MARKER = "\x00\xAA\xCC\x55";
const SPIFLASHLOGGER_OBJECT_MARKER_SIZE = 4;

const SPIFLASHLOGGER_OBJECT_HDR_SIZE = 7;       // SPIFLASHLOGGER_OBJECT_MARKER (4 bytes) + size (2 bytes) + crc (1 byte)
const SPIFLASHLOGGER_OBJECT_MIN_SIZE = 6;       // SPIFLASHLOGGER_OBJECT_MARKER (4 bytes) + size (2 bytes)

const SPIFLASHLOGGER_SECTOR_DIRTY = 0x00;       // Flag for dirty sectors
const SPIFLASHLOGGER_SECTOR_CLEAN = 0xFF;       // Flag for clean sectors


class SPIFlashLogger {

    //static version = [3,0,0];

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

    constructor(start = null, end = null, flash = null, serializer = null) {
        // Set the SPIFlash, or try and set with hardware.spiflash
        try { _flash = flash ? flash : hardware.spiflash; }
        catch (e) { throw "Missing requirement (hardware.spiflash). For more information see: https://github.com/electricimp/spiflashlogger"; }

        // Set the serizlier, or try and set with Serializer
        try { _serializer = serializer ? serializer : Serializer; }
        catch (e) { throw "Missing requirement (Serializer). For more information see: https://github.com/electricimp/spiflashlogger"; }

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
        if (_end > _size) throw "Invalid end parameter (end must be <= size of SPI flash)";
        if (_start % SPIFLASHLOGGER_SECTOR_SIZE != 0) throw "Invalid start parameter (start must be at a sector boundary)";
        if (_end % SPIFLASHLOGGER_SECTOR_SIZE != 0) throw "Invalid end parameter (end must be at a sector boundary)";

        // Set the other utility properties
        _len = _end - _start;
        _sectors = _len / SPIFLASHLOGGER_SECTOR_SIZE;
        _max_data = _sectors * SPIFLASHLOGGER_SECTOR_BODY_SIZE;

        // Can compress this by eight by using bits instead of bytes
        _map = blob(_sectors);

        // Initialise the values by reading the metadata
        _init();
    }

    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end, "sectors": _sectors, "sector_size": SPIFLASHLOGGER_SECTOR_SIZE }
    }

    function write(object) {
        // Check of the object will fit
        local obj_len = _serializer.sizeof(object, SPIFLASHLOGGER_OBJECT_MARKER);
        if (obj_len > _max_data) throw "Cannot store objects larger than alloted memory."

        // Serialize the object
        local obj = _serializer.serialize(object, SPIFLASHLOGGER_OBJECT_MARKER);

        _enable();

        local startAddr = null

        // Write one sector at a time with the metadata attached
        local obj_pos = 0;
        local obj_remaining = obj_len;
        do {

            // How far are we from the end of the sector
            if (_at_pos < SPIFLASHLOGGER_SECTOR_META_SIZE) _at_pos = SPIFLASHLOGGER_SECTOR_META_SIZE;
            local sec_remaining = SPIFLASHLOGGER_SECTOR_SIZE - _at_pos;
            if (obj_remaining < sec_remaining) sec_remaining = obj_remaining;

            // We are too close to the end of the sector, skip to the next sector
            if (obj_pos == 0 && sec_remaining < SPIFLASHLOGGER_OBJECT_MIN_SIZE) {
                _at_sec = (_at_sec + 1) % _sectors;
                _at_pos = SPIFLASHLOGGER_SECTOR_META_SIZE;
            }

            if(startAddr == null)
                startAddr = _start + _at_sec * SPIFLASHLOGGER_SECTOR_SIZE + _at_pos

            // Now write the data
            _write(obj, _at_sec, _at_pos, obj_pos, sec_remaining);
            _map[_at_sec] = SPIFLASHLOGGER_SECTOR_DIRTY;

            // Update the positions
            obj_pos += sec_remaining;
            obj_remaining -= sec_remaining;
            _at_pos += sec_remaining;
            if (_at_pos >= SPIFLASHLOGGER_SECTOR_SIZE) {
                _at_sec = (_at_sec + 1) % _sectors;
                _at_pos = SPIFLASHLOGGER_SECTOR_META_SIZE;
            }
        } while (obj_remaining > 0);

        _disable();

        return startAddr;
    }

    function read(onData = null, onFinish = null, step = 1, skip = 0) {
        assert(typeof step == "integer" && step != 0);

        // skipped tracks how many entries we have skipped, in order to implement skip
        local skipped = math.abs(step) - skip - 1;
        local count = 0;
        local _at_sec = this._at_sec;   // shadow this locally so that when it gets mucked around by a simultaneous (okay during our async operation) .write, things stay happy and healthy in our read

        // function to read one sector, optionally continuing to the next one
        local readSector;
        readSector = function(i) {

            if (i >= _sectors){
                if (onFinish != null) {
                    onFinish()
                    onFinish = null // Prevent a race condition (//TODO: not quite sure what it is..., but I believe it has something to do with returning SPIFLASHLOGGER_OBJECT_MARKER) that calls onFinish multiple times
                }
                return;
            };

            // convert sector index `i`, ordered by recency, to physical `sector`, ordered by position on disk
            local sector;
            if (step > 0) {
                sector = (_at_sec + i + 1) % _sectors;
            } else {
                sector = (_at_sec - i + _sectors) % _sectors;
            }

            local addrs_b = _getObjAddrs(sector);

            if (addrs_b.len() == 0) {
                return imp.wakeup(0, function() {
                    readSector(i + 1);
                }.bindenv(this))
            };

            if (step < 0) {
                // negative step, go backwards
                // `skip` will take care of the magnitude of the steps
                addrs_b.seek(-2, 'e');
            }


            local addr, spi_addr, obj, readObj, cont, seekTo;

            // Passed in to the read callback to be called as `next`
            cont = function(keepGoing = true) {
                if (keepGoing == false) {
                    // Clean up and exit
                    addrs_b = obj = null;
                    if (onFinish != null) { onFinish(); onFinish = null; }
                } else if ((addrs_b.seek(seekTo, 'c') == -1 || addrs_b.eos() == 1)) {
                    //  ^ Try to seek to the next available object
                    // If we've exhausted all addresses found in this sector, move on to the next
                    return imp.wakeup(0, function() {
                        readSector(i + 1);
                    }.bindenv(this));
                } else {
                    // There are more objects to read, read the next one
                    return imp.wakeup(0, readObj.bindenv(this));
                }
            };

            readObj =  function() {

                if (++skipped == math.abs(step)) {
                    // We are not skipping this object, reset `skipped` count
                    skipped = 0;
                    // Get the address (offset from the end of this sectors meta)
                    addr = addrs_b.readn('w');
                    // Calculate the raw spiflash address
                    spi_addr = _start + sector * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_META_SIZE + addr;
                    // Read the object
                    obj = _getObj(spi_addr);

                    // If we're moving backwards, do so, otherwise our blob cursor is
                    // already moved forward by reading
                    if (step < 0) seekTo = -4;
                    else seekTo = 0

                    return onData(obj, spi_addr, cont.bindenv(this));

                } else {
                    // We need to skip more
                    if (step < 0) seekTo = -2;
                    else seekTo = 2

                    // continue
                    return cont();

                }

            }.bindenv(this);

            imp.wakeup(0, readObj.bindenv(this));  // start reading objects in this sector

        }.bindenv(this)

        imp.wakeup(0, function() {
            readSector(0); // start reading sectors
        });
    }

    function readSync(index = 1) {
        assert(typeof index == "integer" && index != 0);

        local skipped = -math.abs(index) + 1

        local readSector;
        readSector = function(i) {
             if (i >= _sectors)  // Read requested index greater than our number of logs - return null;
                return null;

            // start reading sectors
            // convert sector index `i`, ordered by recency, to physical `sector`, ordered by position on disk
            local sector;
            if (index > 0) {
                sector = (_at_sec + i + 1) % _sectors;
            } else {
                sector = (_at_sec - i + _sectors) % _sectors;
            }

            local addrs_b = _getObjAddrs(sector);

            if (addrs_b.len() == 0)
                return readSector(i+1)  //TODO: Get rid of my good friend syncronous recursion?

            if (index < 0) // negative index, go backwards
                addrs_b.seek(-2, 'e');

            local addr, spi_addr, obj, readObj, seekTo;

            if (index < 0) seekTo = -2;
            else seekTo = 2

            while(++skipped != 1) {  //TODO: Get rid of my good friend the while loop?
                if ((addrs_b.seek(seekTo, 'c') == -1 || addrs_b.eos() == 1)) {
                     //  ^ Try to seek to the next available object
                     // If we've exhausted all addresses found in this sector, move on to the next
                     return readSector(i + 1) //TODO: Get rid of my good friend syncronous recursion?
                 }
            }

            // Get the address (offset from the end of this sectors meta)
            addr = addrs_b.readn('w');
            // Calculate the raw spiflash address
            spi_addr = _start + sector * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_META_SIZE + addr;
            // Read the object
            return  _getObj(spi_addr);

        }.bindenv(this)

        return readSector(0); // start reading sectors
    }

    function first(defaultVal=null) {
      local data = this.readSync(1);
      return data == null ? defaultVal : data
    }

    function last(defaultVal=null) {
      local data = this.readSync(-1);
      return data == null ? defaultVal : data
    }

    // Erases all dirty sectors, or an individual object
    function erase(addr = null) {
        if (addr == null) return eraseAll();
        else return _eraseObject(addr);
    }

    // Hard erase all sectors
    function eraseAll(force = false) {
        for (local sector = 0; sector < _sectors; sector++) {
            if (force || _map[sector] == SPIFLASHLOGGER_SECTOR_DIRTY) {
                _erase(sector);
            }
        }
    }

    function getPosition() {
        // Return the current pointer (sector + offset)
        return _at_sec * SPIFLASHLOGGER_SECTOR_SIZE + _at_pos;
    }

    function setPosition(position) {
        // Grab the sector and offset from the position
        local sector = position / SPIFLASHLOGGER_SECTOR_SIZE;
        local offset = position % SPIFLASHLOGGER_SECTOR_SIZE;

        // Validate sector and position
        if (sector < 0 || sector >= _sectors) throw "Position out of range";

        // Set the current sector and position
        _at_sec = sector;
        _at_pos = offset;
    }

    function _enable() {
        // Check _enables then increment
        if (_enables == 0) {
            _flash.enable();
        }

        _enables += 1;
    }

    function _disable() {
        // Decrement _enables then check
        _enables -= 1;

        if (_enables == 0)  {
            _flash.disable();
        }
    }

    // Gets the logged object at the specified position
    function _getObj(pos, cb = null) {
        local requested_pos = pos;

        _enable();
        // Get the meta (for checking) and the object length (to know how much to read)
        local marker = _flash.read(pos, SPIFLASHLOGGER_OBJECT_MARKER_SIZE).tostring();
        local len = _flash.read(pos + SPIFLASHLOGGER_OBJECT_MARKER_SIZE, 2).readn('w');
        _disable();

        if (marker != SPIFLASHLOGGER_OBJECT_MARKER) {   // This allows for simultaneous reading and erasing from the SPIFlashLogger
            // server.error("WARNING: marker not found at " + pos);
			if (cb) cb(SPIFLASHLOGGER_OBJECT_MARKER);
        	else return SPIFLASHLOGGER_OBJECT_MARKER;
        }

        local serialised = blob(SPIFLASHLOGGER_OBJECT_HDR_SIZE + len);

        local leftInObject;
        _enable();
        // while there is more object left, read as much as we can from each sector into `serialised`
        while (leftInObject = serialised.len() - serialised.tell()) {
            // Decide what to read
            local sectorStart = pos - (pos % SPIFLASHLOGGER_SECTOR_SIZE);
            local sectorEnd = sectorStart + SPIFLASHLOGGER_SECTOR_SIZE;// MINUS ONE?
            local leftInSector = sectorEnd - pos;

            // Read it
            local read;
            if (leftInObject < leftInSector) {
                read = _flash.read(pos, leftInObject);
                assert(read.len() == leftInObject);
            } else {
                read = _flash.read(pos, leftInSector);
                assert(read.len() == leftInSector);
            }

            serialised.writeblob(read);

            // Update remaining and position
            leftInObject -= read.len();

            pos += read.len();
            assert (pos <= sectorEnd);

            if (pos == _end) pos = _start + SPIFLASHLOGGER_SECTOR_META_SIZE;
            else if (pos == sectorEnd) pos += SPIFLASHLOGGER_SECTOR_META_SIZE;

        }
        _disable();

        // Try to deserialize the object
        local obj;
        try {
            obj = _serializer.deserialize(serialised, SPIFLASHLOGGER_OBJECT_MARKER);
        } catch (e) {
            server.error(format("Exception reading logger object address 0x%04x with length %d: %s", requested_pos, serialised.len(), e));
            obj = null;
        }

        if (cb) cb(obj);
        else return obj;
    }

    // Returns a blob of 16 bit address of starts of objects, relative to sector body start
    function _getObjAddrs(sector_idx) {
        local from = 0,        // index to search form
              addrs = blob(),  // addresses of starts of objects
              found;

        // Sector clean
        if (_map[sector_idx] != SPIFLASHLOGGER_SECTOR_DIRTY) return addrs;

        local data_start = _start + sector_idx * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_META_SIZE;
        local readLength = SPIFLASHLOGGER_SECTOR_BODY_SIZE;
        _enable();
        local sector_data = _flash.read(data_start, readLength).tostring();
        _disable();
        if (sector_data == null) return addrs;

        while ((found = sector_data.find(SPIFLASHLOGGER_OBJECT_MARKER, from)) != null) {
            // Found an object start, save the address
            addrs.writen(found, 'w');
            // Skip the one we just found the next time around
            from = found + 1;
        }

        addrs.seek(0);
        return addrs;
    }

    function _write(object, sector, pos, object_pos = 0, len = null) {
        if (len == null) len = object.len();

        // Prepare the new metadata
        local meta = blob(6);

        // Erase the sector(s) if it is dirty but not if we are appending
        local appending = (pos > SPIFLASHLOGGER_SECTOR_META_SIZE);
        if (_map[sector] == SPIFLASHLOGGER_SECTOR_DIRTY && !appending) {
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
        local bit_start = math.floor(1.0 * pos / SPIFLASHLOGGER_CHUNK_SIZE).tointeger();
        local bit_finish = math.ceil(1.0 * (pos+len) / SPIFLASHLOGGER_CHUNK_SIZE).tointeger();
        for (local bit = bit_start; bit < bit_finish; bit++) {
            local mod = 1 << bit;
            chunk_map = chunk_map ^ mod;
        }
        meta.writen(chunk_map, 'w');

        // Write the metadata and the data
        local start = _start + (sector * SPIFLASHLOGGER_SECTOR_SIZE);
        _enable();
        _flash.write(start, meta, SPIFLASH_POSTVERIFY);
        local res = _flash.write(start + pos, object, SPIFLASH_POSTVERIFY, object_pos, object_pos+len);
        _disable();

        if (res != 0) {
            throw format("Writing failed from object position %d of %d, to 0x%06x (meta), 0x%06x (body)", object_pos, len, start, start + pos)
            return null;
        } else {
            // server.log(format("Written to: 0x%06x (meta), 0x%06x (body) of: %d", start, start + pos, object_pos));
        }

        return len;
    }

    // Erases the marker to make an object invisible
    function _eraseObject(addr) {

        if (addr == null) return false;

        // Erase the marker for the entry we found
        _enable();
        local check = _flash.read(addr, SPIFLASHLOGGER_OBJECT_MARKER_SIZE);
        if (check.tostring() != SPIFLASHLOGGER_OBJECT_MARKER) {
            server.error("Object address invalid. No marker found.")
            _disable();
            return false;
        }
        local clear = blob(SPIFLASHLOGGER_OBJECT_MARKER_SIZE);
        local res = _flash.write(addr, clear, SPIFLASH_POSTVERIFY);
        _disable();

        if (res != 0) {
            server.error("Clearing object marker failed.");
            return false;
        }

        return true;

    }

    function _getSectorMetadata(sector) {
        // NOTE: Should we skip clean sectors automatically?
        _enable();
        local start = _start + (sector * SPIFLASHLOGGER_SECTOR_SIZE);
        local meta = _flash.read(start, SPIFLASHLOGGER_SECTOR_META_SIZE);
        // Parse the meta data
        meta.seek(0);
        _disable();

        return { "id": meta.readn('i'), "map": meta.readn('w') };
    }

    function _dirtyChunkCount(sector) {
        local map = _getSectorMetadata(sector).map;
        local count, mask;
        for (count = 0, mask = 0x0001; mask < 0x8000; mask = mask << 1) {
            if (!(map & mask)) count++;
            else break;
        }
        return count+1;// TODO: why was this plus one necessary?
    }

    function _init() {
        local best_id = 0;          // The highest id
        local best_sec = 0;         // The sector with the highest id
        local best_map = 0xFFFF;    // The map of the sector with the highest id

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
                _map[sector] = SPIFLASHLOGGER_SECTOR_CLEAN;
            }
        }
        _disable();

        _at_pos = 0;
        _at_sec = best_sec;
        _next_sec_id = best_id+1;
        for (local bit = 1; bit <= 16; bit++) {
            local mod = 1 << bit;
            _at_pos += (~best_map & mod) ? SPIFLASHLOGGER_CHUNK_SIZE : 0;
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
            _flash.erasesector(_start + (sector * SPIFLASHLOGGER_SECTOR_SIZE));
            // server.log(format("Erasing: %d (0x%04x)", sector, _start + (sector * SPIFLASHLOGGER_SECTOR_SIZE)));

            // Mark the sector as clean
            _map[sector] = SPIFLASHLOGGER_SECTOR_CLEAN;

            // Move the pointer on to the next sector
            if (!preparing && sector == _at_sec) {
                _at_sec = (_at_sec + 1) % _sectors;
                _at_pos = SPIFLASHLOGGER_SECTOR_META_SIZE;
            }
        }
        _disable();
    }
}
