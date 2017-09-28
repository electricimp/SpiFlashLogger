// MIT License
//
// Copyright 2017 Electric Imp
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

// Using `const`s instead of `static`s for performance
const SPIFLASHLOGGER_SECTOR_SIZE = 4096; // Size of sectors
const SPIFLASHLOGGER_SECTOR_METADATA_SIZE = 3; // Size of metadata at start of sectors
const SPIFLASHLOGGER_SECTOR_BODY_SIZE = 4093; // Size of writeable memory / sector
const SPIFLASHLOGGER_CHUNK_SIZE = 256; // Number of bytes we write / operation

const SPIFLASHLOGGER_OBJECT_MARKER = "\x00\xAA\xCC\x55";
const SPIFLASHLOGGER_OBJECT_MARKER_SIZE = 4;

const SPIFLASHLOGGER_OBJECT_HDR_SIZE = 7; // SPIFLASHLOGGER_OBJECT_MARKER (4 bytes) + size (2 bytes) + crc (1 byte)
const SPIFLASHLOGGER_OBJECT_MIN_SIZE = 6; // SPIFLASHLOGGER_OBJECT_MARKER (4 bytes) + size (2 bytes)

const SPIFLASHLOGGER_SECTOR_DIRTY = 0x00; // Flag for dirty sectors
const SPIFLASHLOGGER_SECTOR_CLEAN = 0xFF; // Flag for clean sectors


class SPIFlashLogger {

    static version = "3.0.0";

    _flash = null; // hardware.spiflash or an object with an equivalent interface
    _serializer = null; // github.com/electricimp/serializer (or an object with an equivalent interface)

    _size = null; // The size of the spiflash
    _start = null; // First block to use for logging
    _end = null; // Last block to use for logging
    _len = null; // The length of the flash available (end-start)
    _sectors = 0; // The number of sectors in _len
    _max_data = 0; // The maximum data we can push at once

    _at_sec = 0; // Current sector we're writing to
    _at_pos = 0; // Current position we're writing to in the sector

    _enables = 0; // Counting semaphore for _enable/_disable
    _sectorsMap = null; // list of sector objects

    constructor(start = null, end = null, flash = null, serializer = null) {
        // Set the SPIFlash, or try and set with hardware.spiflash
        try {
            _flash = flash ? flash : hardware.spiflash;
        } catch (e) {
            throw "Missing requirement (hardware.spiflash). For more information see: https://github.com/electricimp/spiflashlogger";
        }

        // Set the serizlier, or try and set with Serializer
        try {
            _serializer = serializer ? serializer : Serializer;
        } catch (e) {
            throw "Missing requirement (Serializer). For more information see: https://github.com/electricimp/spiflashlogger";
        }

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

        // Initialise the values by reading the metadata
        _init();
    }

    function dimensions() {
        return {
            "size": _size,
            "len": _len,
            "start": _start,
            "end": _end,
            "sectors": _sectors,
            "sector_size": SPIFLASHLOGGER_SECTOR_SIZE
        }
    }

    function write(object) {
        // Check of the object will fit
        local obj_len = _serializer.sizeof(object, SPIFLASHLOGGER_OBJECT_MARKER);
        if (obj_len > _max_data) throw "Cannot store objects larger than allocated memory."

        // Serialize the object
        local obj = _serializer.serialize(object, SPIFLASHLOGGER_OBJECT_MARKER);

        _enable();

        // Write one sector at a time with the metadata attached
        local obj_pos = 0;
        local obj_remaining = obj_len;
        do {
            local written = _sectorsMap[_at_sec].write(obj, obj_pos, obj_remaining);
            obj_remaining = obj_remaining - written;
            // Object (or partial object) should allocate all memory on the flash sector
            // otherwise we will have gap in object writing.
            if (obj_remaining != 0 && _sectorsMap[_at_sec].getFreeSpace() > 0)
                throw "Failed to write data on the flash.";

            if (_sectorsMap[_at_sec].getFreeSpace() <= SPIFLASHLOGGER_OBJECT_MIN_SIZE) {
                _at_sec = (_at_sec + 1) % _sectors;
                // erase and mark as start next sector
                _sectorsMap[_at_sec]._prepareForWrite();
                _at_pos = _sectorsMap[_at_sec].getWritePosition();
            } else {
                _at_pos += written;
            }
        } while (obj_remaining > 0);

        _disable();
    }

    function read(onData = null, onFinish = null, step = 1, skip = 0) {
        assert(typeof step == "integer" && step != 0);

        if (skip < 0) {
            throw "Wrong skip parameter value.";
        }

        // skipped tracks how many entries we have skipped, in order to implement skip
        local skipped = math.abs(step) - skip - 1;
        local count = 0;
        local objectIterator = _getObjectIterator(step);
        // There is no start point for object iteration
        if (objectIterator == null) {
            if (onFinish != null)
                onFinish();
            return;
        }

        local continueCallback, readNextObject;
        // Passed in to the read callback to be called as `next`
        continueCallback = function(keepGoing = true) {
            if (keepGoing == false) {
                // Clean up and exit
                objectIterator = null;
                if (onFinish != null)
                    onFinish();
            } else {
                // There are more objects to read, read the next one
                return imp.wakeup(0, readNextObject.bindenv(this));
            }
        };

        readNextObject = function() {
            local obj = objectIterator.getNextObject(step, skip);
            if (obj != null && obj.isValid()) {
                return onData(obj.getPayload(),
                    obj.getAddress(), continueCallback.bindenv(this));
            } else {
                return continueCallback(false);
            }
            return true;
        }.bindenv(this);

        // start reading objects in this sector
        imp.wakeup(0, function() {
            return continueCallback(true);
        }.bindenv(this));
    }

    function readSync(index) {
        return _getObjectIterator.getNextObject(index);
    }

    function _getObjectIterator(index) {
        if (typeof index != "integer" || index == 0)
            throw "Invalid argument.";
        if (index < 0) {
            local objectIterator = LoggerObjectIterator(this, _flash);
            return objectIterator;
        }

        local sec = _at_sec;
        local counter = 0;
        do {
            sec = (sec + 1) % _sectors;
            ++counter;
        } while (!_sectorsMap[sec].isStoppedWriting() &&
            !_sectorsMap[sec].isStartWriting() &&
            counter <= _sectors);
        if (!_sectorsMap[sec].isStoppedWriting() &&
            !_sectorsMap[sec].isStartWriting())
            return null;
        // Create object iterator from start position sector
        local objectIterator = LoggerObjectIterator(this, _flash, _start + sec * SPIFLASHLOGGER_SECTOR_SIZE);
        return objectIterator;
    }

    function first(defaultVal = null) {
        local data = this.readSync(1);
        return data == null ? defaultVal : data
    }

    function last(defaultVal = null) {
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
            if (force || !_sectorsMap[sector].isFree()) {
                _erase(sector);
            }
        }
        _at_sec = 0;
        _at_pos = _sectorsMap[_at_sec].getWritePosition();
    }
    //
    // Get current spi flash writing address
    // @return - an absolute position on the spi flash
    function getPosition() {
        // Return the current pointer (sector + offset)
        return _start + _at_sec * SPIFLASHLOGGER_SECTOR_SIZE + _at_pos;
    }

    //
    // Set spi flash writing address
    // @param {int} - an absolute address on the flash
    //
    function setPosition(position) {
        // Grab the sector and offset from the position
        local sector = position / SPIFLASHLOGGER_SECTOR_SIZE;
        local offset = position % SPIFLASHLOGGER_SECTOR_SIZE;

        // Validate sector and position
        if (sector < 0 || sector >= _sectors) throw "Position out of range";

        // Set the current sector and position
        _at_sec = sector;
        //_at_pos = offset < SPIFLASHLOGGER_SECTOR_METADATA_SIZE ? SPIFLASHLOGGER_SECTOR_METADATA_SIZE : offset;

        _at_pos = offset > SPIFLASHLOGGER_SECTOR_METADATA_SIZE ? offset : SPIFLASHLOGGER_SECTOR_METADATA_SIZE;

        _sectorsMap[_at_sec].setPosition(_at_pos);
    }

    //
    // Enable SPI Flash writing
    //
    function _enable() {
        // Check _enables then increment
        if (_enables == 0) {
            _flash.enable();
        }

        _enables += 1;
    }

    //
    // Disable spi flash writing
    //
    function _disable() {
        // Decrement _enables then check
        _enables -= 1;

        if (_enables == 0) {
            _flash.disable();
        }
    }

    //
    // Erases the marker to make an object invisible
    // @param {int} - an absolute address of object
    //
    function _eraseObject(addr) {

        if (addr == null) return false;

        local obj = LoggerSerializedObject(addr, this, _flash);
        if (!obj.isValid())
            return false;
        return obj.erase();
    }

    //
    // Initialize logger
    //
    function _init() {
        // suppose that flash is clean
        _at_pos = 0;
        _sectorsMap = [];

        local hasWrongSector = false;

        // Read all the metadata
        local found_last_pos = false;
        for (local sector = 0; sector < _sectors; sector++) {
            local sectorItem =
                LoggerSector(_start + sector * SPIFLASHLOGGER_SECTOR_SIZE,
                    _start + (sector + 1) * SPIFLASHLOGGER_SECTOR_SIZE,
                    _flash,
                    this);
            sectorItem.init();
            _sectorsMap.push(sectorItem);
            //
            // Buffer is circular therefore we are not expecting
            // free sector before latest working sector
            // Note: throw error in case of several start codes
            if (sectorItem.isStartWriting() && !sectorItem.isStoppedWriting()) {
                // By default writing address
                // is rounded to the chunk
                _at_pos = sectorItem.getWritePosition();
                _at_sec = sector;
                // Check that it is a new start position
                if (found_last_pos)
                    // Found several start positions.
                    hasWrongSector = true;
                found_last_pos = true;
            } else if (sectorItem.isFree() && !found_last_pos) {
                found_last_pos = true;
                _at_pos = sectorItem.getWritePosition();
                _at_sec = sector;
            }
        }
        // Clear flash if it has wrong sectors
        if (hasWrongSector) {
            eraseAll(true);
        }
    }

    //
    // Erase sectors from start to end
    //
    // @param {int} - from sector address
    // @param {int} - till sector address
    // @param {bool} - skip preparing sector
    function _erase(start_sector = null, end_sector = null, preparing = false) {
        if (start_sector == null) {
            start_sector = 0;
            end_sector = _sectors;
        }

        if (end_sector == null)
            end_sector = start_sector + 1;

        if (start_sector < 0 || end_sector > _sectors)
            throw "Invalid format request";

        _enable();

        for (local sector = start_sector; sector < end_sector; sector++) {
            // Erase the requested sector
            _flash.erasesector(_start + (sector * SPIFLASHLOGGER_SECTOR_SIZE));
            // reinit current sector as free
            if (!preparing)
                _sectorsMap[sector].init();
        }
        _disable();
    }
}

class SPIFlashLogger.LoggerSector {
    // position for reading
    _pos_read = 0;
    // position for writing
    _pos_write = 0;
    // start/end address
    _start = 0;
    _end = 0;
    // spi flash object
    _flash = null;
    _logger = null;
    // indicates if we need to erase sector before write
    _eraseBeforeWrite = false;

    // Default status of sector is free
    // which is equal to the 0xFFFFFF
    static SECTOR_STATUS_FREE = 0;
    // Indicates that we can read metadata from that sector
    static SECTOR_HAS_METADATA = 1;
    // Indicates that sector has some written data
    static SECTOR_WRITE_START = 1 << 1;
    // Indicates that sector was closed on writing
    static SECTOR_WRITE_DONE = 1 << 2;
    // Indicates that sector has at least one start code
    static SECTOR_HAS_START_CODE = 1 << 3;
    // indicates that start code could be invalid
    // because object was erased
    static SECTOR_HAS_REMOVED_OBJECT = 1 << 4;

    // header bytes with status of current sector
    _status = 0xFFFF;
    // chunk map indicates if all chunks are busy
    // 0 - chunk was written
    // 1 - chunk is free
    _chunkMap = 0xFFFF;

    //
    // Make a flash sector object
    // @param {integer} - start address of sector
    // @param {integer} - end address of sector
    // @param {Flash} - hardware.spiflash object
    // @param {SPIFlashLogger} - parent class instance
    constructor(start = 0, end = null, flash = null, logger = null) {
        _start = start;
        _end = end;
        _flash = flash;
        _logger = logger;
        _pos_write = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
    }

    // read current status of flash's sector
    function init() {
        _logger._enable();
        local meta = _flash.read(_start, SPIFLASHLOGGER_SECTOR_METADATA_SIZE);
        _logger._disable();
        // Parse the meta data
        meta.seek(0);
        // read first 6 bytes
        _status = meta.readn('b');
        _chunkMap = meta.readn('w');

        if (isStoppedWriting()) {
            _pos_write = SPIFLASHLOGGER_SECTOR_SIZE;
        } else if (isStartWriting()) {
            _pos_write = getFreeChunkAddress();
        } else if (isFree()) {
            _pos_write = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
        }
    }

    function getFreeSpace() {
        // there is no free space if sector
        // was closed for writing
        if (~_status & SECTOR_WRITE_DONE)
            return 0;
        return SPIFLASHLOGGER_SECTOR_SIZE - _pos_write;
    }

    function _prepareForWrite() {
        // clean and re-init sector
        if (!this.isFree())
            erase();
    }

    function write(object, object_pos = 0, len = null) {
        if (len == null)
            len = object.len();
        if (len > getFreeSpace())
            len = getFreeSpace();

        if (_eraseBeforeWrite)
            erase();

        local meta = _getUpdatedMetadataBlob(len, object_pos == 0);

        // Write the metadata and the data
        _logger._enable();
        local mres = _flash.write(_start, meta, SPIFLASH_POSTVERIFY);
        local res = _flash.write(_start + _pos_write, object, SPIFLASH_POSTVERIFY, object_pos, object_pos + len);
        _logger._disable();

        if (mres != 0 || res != 0) {
            throw format("Writing failed from object position %d of %d, to 0x%06x (meta), 0x%06x (body)", object_pos, len, _start, _start + _pos_write)
            return null;
        } else {
            // server.log(format("Written to: 0x%06x (meta), 0x%06x (body) of: %d", _start, _start + _pos_write, object_pos));
        }
        _pos_write += len;
        return len;
    }

    function _getUpdatedMetadataBlob(length, hasStartCode) {
        // Prepare the new metadata
        local meta = blob(SPIFLASHLOGGER_SECTOR_METADATA_SIZE);

        // Write the new usage map, changing only the bit in this write
        local bit_start = math.floor(1.0 * _pos_write / SPIFLASHLOGGER_CHUNK_SIZE).tointeger();
        local bit_finish = math.ceil(1.0 * (_pos_write + length) / SPIFLASHLOGGER_CHUNK_SIZE).tointeger();
        for (local bit = bit_start; bit < bit_finish; bit++) {
            local mod = 1 << bit;
            this._chunkMap = this._chunkMap & ~mod;
        }
        // object will take all free space on this flash
        if (length >= getFreeSpace() - SPIFLASHLOGGER_OBJECT_MIN_SIZE) {
            _status = _status & ~SECTOR_WRITE_DONE;
        }

        // mark sector as write started
        if (isFree()) {
            _status = _status & ~SECTOR_WRITE_START;
        }

        if (hasStartCode) {
            _status = _status & ~SECTOR_HAS_START_CODE;
        }

        // Mark sector as first metadata written
        _status = _status & ~SECTOR_HAS_METADATA;

        // Sector status information
        meta.writen(this._status, 'b');
        // Chunk payload information
        meta.writen(this._chunkMap, 'w');

        return meta;
    }

    // Returns a blob of 16 bit address of starts of objects, relative to sector body start
    function getObjectAddresses(backward = true, address = SPIFLASHLOGGER_SECTOR_SIZE) {
        local from = 0, // index to search form
            addrs = blob(), // addresses of starts of objects
            found;

        // Check if sector has start code
        if (!hasStartCode()) return addrs;

        local data_start = _start + SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
        local readLength = SPIFLASHLOGGER_SECTOR_BODY_SIZE;
        _logger._enable();
        local sector_data = _flash.read(data_start, readLength).tostring();
        _logger._disable();
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

    //
    // indicates if sector has start code
    function hasStartCode() {
        return ~this._status & SECTOR_HAS_START_CODE;
    }

    function isStartWriting() {
        return ~this._status & SECTOR_WRITE_START;
    }

    function isStoppedWriting() {
        return ~this._status & SECTOR_WRITE_DONE;
    }

    function getWritePosition() {
        return _pos_write;
    }

    function getFreeChunkAddress() {
        local i = 0;
        do {
            if (this._chunkMap & (1 << i))
                return (i == 0 ? SPIFLASHLOGGER_SECTOR_METADATA_SIZE : i * SPIFLASHLOGGER_CHUNK_SIZE);
            ++i;
        } while (i <= (SPIFLASHLOGGER_SECTOR_SIZE / SPIFLASHLOGGER_CHUNK_SIZE));
        // there is no free free chunk, all sector is busy
        return SPIFLASHLOGGER_SECTOR_SIZE;
    }

    function isFree() {
        return this._status == 0xFF;
    }

    function erase() {
        // Erase sector
        local sec = (this._start - _logger._start) / SPIFLASHLOGGER_SECTOR_SIZE;
        // erase current sector
        _logger._erase(sec, sec + 1);

        this._status = 0xFF;
        this._chunkMap = 0xFF;
        this._pos_write = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
        this._pos_read = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;

        _eraseBeforeWrite = false;
    }

    function setPosition(pos) {
        if ((math.abs(pos - _pos_write) > SPIFLASHLOGGER_CHUNK_SIZE) ||
            (pos <= SPIFLASHLOGGER_SECTOR_METADATA_SIZE && !this.isFree() ||
                this.isStoppedWriting())) {
            // Wrong position
            _eraseBeforeWrite = true;
        } else
            _pos_write = pos;
    }
};

class SPIFlashLogger.LoggerSerializedObject {
    _flash = null;
    _logger = null;
    _addr = null;
    _isValid = false;
    _payload = null;
    _len = 0;

    constructor(addr, logger, flash) {
        _logger = logger;
        _flash = flash;
        _addr = addr;

        _isValid = false;
        _payload = null;
        _len = 0;

        init(addr);
    }

    function init(pos) {
        local requested_pos = pos;
        _logger._enable();
        // Get the meta (for checking) and the object length (to know how much to read)
        local marker = _flash.read(pos, SPIFLASHLOGGER_OBJECT_MARKER_SIZE).tostring();
        local len = _flash.read(pos + SPIFLASHLOGGER_OBJECT_MARKER_SIZE, 2).readn('w');
        _logger._disable();
        _len = len;
        _isValid = (marker == SPIFLASHLOGGER_OBJECT_MARKER && len > 0 && len < _logger._size);
    }

    function isValid() {
        return _isValid;
    }

    function getAddress() {
        return _addr;
    }

    function getPayload() {
        if (!_isValid)
            return null;

        if (_payload != null)
            return _payload;

        local pos = _addr;
        local serialised = blob(SPIFLASHLOGGER_OBJECT_HDR_SIZE + _len);
        local leftInObject;
        _logger._enable();
        // while there is more object left, read as much as we can from each sector into `serialised`
        while (leftInObject = serialised.len() - serialised.tell()) {
            // Decide what to read
            local sectorStart = pos - (pos % SPIFLASHLOGGER_SECTOR_SIZE);
            local sectorEnd = sectorStart + SPIFLASHLOGGER_SECTOR_SIZE;
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
            assert(pos <= sectorEnd);

            if (pos == _logger._end) pos = _logger._start + SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
            else if (pos == sectorEnd) pos += SPIFLASHLOGGER_SECTOR_METADATA_SIZE;

        }
        _logger._disable();

        // Try to deserialize the object
        _payload = null;
        try {
            _payload = _logger._serializer.deserialize(serialised, SPIFLASHLOGGER_OBJECT_MARKER);
        } catch (e) {
            //server.error(format("Exception reading logger object address 0x%04x with length %d: %s", requested_pos, serialised.len(), e));
            _payload = null;
        }
        return _payload;
    }

    function erase() {
        _logger._enable();
        local clear = blob(SPIFLASHLOGGER_OBJECT_MARKER_SIZE);
        local res = _flash.write(_addr, clear, SPIFLASH_POSTVERIFY);
        _logger._disable();

        if (res != 0) {
            server.error("Clearing object marker failed.");
            return false;
        }

        return true;
    }
}

class SPIFlashLogger.LoggerObjectIterator {
    _addr = null; // current start address
    _sector = -1; // working sector
    _pos = 0;
    _chunk_addresses = null; // list of cached addresses in chunk
    _cached_obj_index = 0;
    _logger = null;
    _flash = null;

    constructor(logger, flash, addr = null) {
        _logger = logger;
        _flash = flash;
        // get possition indicates current write position
        _addr = (addr == null ? _logger.getPosition() : addr);
        _sector = (_addr - _logger._start) / SPIFLASHLOGGER_SECTOR_SIZE;
        _pos = _addr % SPIFLASHLOGGER_SECTOR_SIZE;
        // align start point
        if (_pos < SPIFLASHLOGGER_SECTOR_METADATA_SIZE)
            _pos = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
    }

    // cached statuses of each sector
    _sector_start_codes = null;
    _start_code_pos = null;
    _sector_available_data = 0;

    function getNextObject(step, skip = 0) {

        local is_init = _sector_start_codes == null;
        local steps_need = is_init ? skip + 1 : math.abs(step);

        if (_sector_available_data < steps_need || _sector_available_data == 0) {

            do {
                // skip all start codes in this sector
                steps_need -= _sector_available_data;
                // find next sector which has start code
                local next = _getNextSectorWithStartCode(_sector, _sector_start_codes == null, step > 0);

                // If there is no more start codes then return
                if (next < 0)
                    return null;

                _sector = next;

                // cache start codes on the next sector
                _sector_start_codes = _logger._sectorsMap[_sector].getObjectAddresses();

                // Something goes wrong, null happens on error only
                if (_sector_start_codes == null)
                    return null;
                // check if cache sector has enough data for the next step
                _sector_available_data = _sector_start_codes.len() / 2;
                _start_code_pos = step > 0 ? 0 : _sector_available_data;
            } while (_sector_available_data < steps_need);
        }

        // No more data for the next step
        if (_sector_available_data < steps_need)
            return null;

        // increase or decrease the current position
        _start_code_pos += (step > 0) ? steps_need - 1 : -steps_need;
        // Each address has 2 bytes in the blob
        _sector_start_codes.seek(_start_code_pos * 2);
        local obj_addr = _sector_start_codes.readn('w');
        _start_code_pos = _start_code_pos + (step > 0 ? 1 : 0);
        _sector_available_data -= steps_need;
        local spi_addr = _logger._start + _sector * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_METADATA_SIZE + obj_addr;
        return SPIFlashLogger.LoggerSerializedObject(spi_addr, _logger, _flash);
    }

    function _isLastSector(current, forward) {
        local is_last_sector = current == _logger._at_sec;
        return is_last_sector;
    }

    function _getNextSectorWithStartCode(current, is_first_search, forward) {
        // work-around for a one-sector logger
        if (!is_first_search && _logger._sectors <= 1)
            return -1;

        local counter = is_first_search ? 0 : 1;
        local next_sector = is_first_search ? -1 : current;

        // Check if it is laster sector
        do {
            if (counter > 0 && next_sector >= 0 && _isLastSector(next_sector, forward))
                return -1;
            next_sector = (current + _logger._sectors + (forward ? counter : -counter)) % _logger._sectors;
            counter++;
            // we are not expecting to find erased sector
            // except first iteration
            if (!is_first_search && _logger._sectorsMap[next_sector].isFree())
                return -1;

        } while (!_logger._sectorsMap[next_sector].hasStartCode() && counter < _logger._sectors - 1)
        if (_logger._sectorsMap[next_sector].hasStartCode())
            return next_sector;
        return -1;
    }
}
