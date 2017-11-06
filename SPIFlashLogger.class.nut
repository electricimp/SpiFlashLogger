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
const SPIFLASHLOGGER_SECTOR_SIZE = 4096;        // Size of sectors
const SPIFLASHLOGGER_SECTOR_METADATA_SIZE = 6;      // Size of metadata at start of sectors
const SPIFLASHLOGGER_SECTOR_BODY_SIZE = 4090;   // Size of writeable memory / sector
const SPIFLASHLOGGER_CHUNK_SIZE = 256;          // Number of bytes we write / operation

const SPIFLASHLOGGER_OBJECT_MARKER = "\x00\xAA\xCC\x55";
const SPIFLASHLOGGER_OBJECT_MARKER_SIZE = 4;

const SPIFLASHLOGGER_OBJECT_HDR_SIZE = 7;       // SPIFLASHLOGGER_OBJECT_MARKER (4 bytes) + size (2 bytes) + crc (1 byte)
const SPIFLASHLOGGER_OBJECT_MIN_SIZE = 6;       // SPIFLASHLOGGER_OBJECT_MARKER (4 bytes) + size (2 bytes)

const SPIFLASHLOGGER_SECTOR_DIRTY = 0x00;       // Flag for dirty sectors
const SPIFLASHLOGGER_SECTOR_CLEAN = 0xFF;       // Flag for clean sectors


// The SPIFlashLogger creates a circular log system,
// allowing you to log any serializable object
// (table, array, string, blob, integer, float, boolean and null) to the SPIFlash.
// If the log system runs out of space in the SPIFlash,
// it begins overwriting the oldest logs.
class SPIFlashLogger {

    static VERSION = "2.2.0";

    _flash = null;      // hardware.spiflash or an object with an equivalent interface
    _serializer = null; // github.com/electricimp/serializer (or an object with an equivalent interface)

    _size = null;       // The size of the spiflash
    _start = null;      // First block to use for logging
    _end = null;        // Last block to use for logging
    _len = null;        // The length of the flash available (end-start)
    _sectors = 0;       // The number of sectors in _len
    _maxData = 0;      // The maximum data we can push at once

    _atSec = 0;        // Current sector we're writing to
    _atPos = 0;        // Current position we're writing to in the sector

    _map = null;        // Array of sector maps
    _enables = 0;       // Counting semaphore for _enable/_disable
    _nextSectorId = 1;   // The next sector we should write to

    // ------------------------ public API -------------------

    //
    // Constructor
    // Parameters:
    //      start        - spi flash start address for the logger
    //      end          - spi flash end address for the logger
    //      flash        - spi flash object see `hardware.spiflash`
    //                     (https://electricimp.com/docs/hardware/spiflash)
    //      serializer   - the serializer instance which is responsible for object
    //                     serialization and de-serialization
    //                     (for example: https://github.com/electricimp/Serializer)
    //
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
        _maxData = _sectors * SPIFLASHLOGGER_SECTOR_BODY_SIZE;

        // Can compress this by eight by using bits instead of bytes
        _map = blob(_sectors);

        // Initialise the values by reading the metadata
        _init();
    }

    // This method returns a table with the following keys,
    // each of which gives access to an integer value:
    //   size    - The size of the SPIFlash in bytes
    //   len     - The number of bytes allocated to the logger
    //   start   - The first byte used by the logger
    //   end     - The last byte used by the logger
    //   sectors - The number of sectors allocated to the logger
    //   sectorSize - The size of sectors in bytes
    function dimensions() {
        return { "size": _size, "len": _len, "start": _start, "end": _end, "sectors": _sectors, "sector_size": SPIFLASHLOGGER_SECTOR_SIZE }
    }

    // Writes any serializable object to the memory allocated
    // for the SPIFlashLogger. If the memory is full,
    // the logger begins overwriting the oldest entries.
    // If the provided object can not be serialized,
    // the exception is thrown by the underlying serializer class.
    //
    // Parameters:
    //    object - an object to serialize and save
    function write(object) {
        // Check of the object will fit
        local objLength = _serializer.sizeof(object, SPIFLASHLOGGER_OBJECT_MARKER);
        if (objLength > _maxData) throw "Cannot store objects larger than alloted memory."

        // Serialize the object
        local obj = _serializer.serialize(object, SPIFLASHLOGGER_OBJECT_MARKER);

        _enable();

        // Write one sector at a time with the metadata attached
        local objPos = 0;
        local objRemaining = objLength;
        do {

            // How far are we from the end of the sector
            if (_atPos < SPIFLASHLOGGER_SECTOR_METADATA_SIZE) _atPos = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
            local secRemaining = SPIFLASHLOGGER_SECTOR_SIZE - _atPos;
            if (objRemaining < secRemaining) secRemaining = objRemaining;

            // We are too close to the end of the sector, skip to the next sector
            if (objPos == 0 && secRemaining < SPIFLASHLOGGER_OBJECT_MIN_SIZE) {
                _atSec = (_atSec + 1) % _sectors;
                _atPos = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
            }
            // Handle overflow use-case for a one-sector logger
            else if (_sectors == 1 && objPos == 0 && objRemaining > secRemaining) {
                eraseAll(true);
                _atPos = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
                secRemaining = objRemaining;
            }

            // Now write the data
            _write(obj, _atSec, _atPos, objPos, secRemaining);
            _map[_atSec] = SPIFLASHLOGGER_SECTOR_DIRTY;

            // Update the positions
            objPos += secRemaining;
            objRemaining -= secRemaining;
            _atPos += secRemaining;
            if (_atPos >= SPIFLASHLOGGER_SECTOR_SIZE) {
                _atSec = (_atSec + 1) % _sectors;
                _atPos = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
            }
        } while (objRemaining > 0);

        _disable();
    }

    // Reads objects from the logger synchronously,
    // returning a single log object for the specified *index*.
    //
    // Returns:
    // Deserialized object or null
    //    - the most recent object when `index == -1`,
    //    - the oldest object when `index == 1`,
    //    - *null* when the value of *index* is greater than the number of logs,
    //    - throws an exception when `index == 0`.
    //
    function readSync(index) {
        // Unexpected index value
        if (index == 0)
            throw "Invalid argument";

        // identify first sector to read
        local seekTo = math.abs(index);
        local count = 0;
        local i = 0;

        // _atSec - indicates the current write sector, therefore
        // for the index > 0 it is necessary to step forward (skip current sector)
        // to find first not empty sector
        // For the index < 0, it is possible to start couting from the current sector
        while (i < _sectors) {
            // convert sector index `i`, ordered by recency, to physical `sector`, ordered by position on disk
            local sector;
            if (index > 0) {
                sector = (_atSec + i + 1) % _sectors;
            } else {
                sector = (_atSec - i + _sectors) % _sectors;
            }

            ++i;

            // Read all objects start codes for current sector
            // and write them into the blob
            local objectsStartCodes = _getObjectsStartCodesForSector(sector);

            // If there is no start codes in the current sector
            // then switch to the next sector
            if (objectsStartCodes == null || objectsStartCodes.len() == 0)
                continue;

            // negative step, go backwards
            if (index < 0)
                objectsStartCodes.seek(-2, 'e');

            // Check that the number of start codes is enough
            // otherwise decrease the seekTo count on a number of objects
            // in the current sector and switch to the next sector
            if (seekTo > objectsStartCodes.len() / 2) {
              seekTo -= objectsStartCodes.len() / 2;
              continue;
            }

            // seek for an object start code
            if (objectsStartCodes.seek((seekTo - 1) * 2 * (index > 0 ? 1 : -1), 'c') == -1 || objectsStartCodes.eos() == 1) {
                // This code should never happen, because
                // the objectsStartCodes blob should have enough data
                // for seek to the seekTo position (check at the previous if-condition)
                server.error("Unexpected error");
                return null;
            }
            // Read the object address
            local addr = objectsStartCodes.readn('w');
            // Get the global object address on the spiflash
            local spiAddr = _start + sector * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_METADATA_SIZE + addr;
            // Read the object by address and return the de-serialized value
            // return null in case of de-serialize object errors
            return _getObject(spiAddr);
        } // while

        return null;
    }

    // Synchronously returns the first object written to the log
    // that hasn't been erased (i.e. the oldest entry on flash).
    // If there are no logs on the flash, returns default.
    function first(defaultVal = null) {
        local data = this.readSync(1);
        return data == null ? defaultVal : data
    }

    // Synchronously returns the last object written to the log
    // that hasn't been erased (i.e. the newest entry on flash).
    // If there are no logs on the flash, returns default.
    function last(defaultVal = null) {
        local data = this.readSync(-1);
        return data == null ? defaultVal : data
    }

    // Reads objects from the logger asynchronously.
    //
    // This mehanism is intended for the asynchronous processing of each log object,
    // such as sending data to the agent and waiting for an acknowledgement.
    //
    // Parameters:
    //
    // onData   - Callback that provides the object which has been read
    //            from the logger
    //
    // onFinish - Callback that is called after the last object is provided
    //            (i.e. there are no more objects to return by the current read operation),
    //            or when the operation it terminated,
    //            or in case of an error The callback has no parameters.
    //
    // step     - The rate at which the read operation steps through the logged
    //            objects. Must not be 0. If it has a positive value the read
    //            operation starts from the oldest logged object.
    //            If it has a negative value, the read operation starts from the
    //            most recently written object and steps backwards. Defaule value: 1
    //
    // skip     - Skips the specified number of the logged objects at the start of
    //            the reading. Must not has a negative value. Default value: 0
    //
    function read(onData = null, onFinish = null, step = 1, skip = 0) {
        assert(typeof step == "integer" && step != 0);

        // skipped tracks how many entries we have skipped, in order to implement skip
        local skipped = math.abs(step) - skip - 1;
        local count = 0;

        // function to read one sector, optionally continuing to the next one
        local readSector;
        local objectsStartCodes = null;
        readSector = function(i) {

            if (i >= _sectors){
                if (onFinish != null) {
                    return onFinish()
                }
                return;
            };

            // convert sector index `i`, ordered by recency, to physical `sector`, ordered by position on disk
            local sector;
            if (step > 0) {
                sector = (_atSec + i + 1) % _sectors;
            } else {
                sector = (_atSec - i + _sectors) % _sectors;
            }

            objectsStartCodes = _getObjectsStartCodesForSector(sector);

            if (objectsStartCodes.len() == 0) {
                return imp.wakeup(0, function() {
                    readSector(i + 1);
                }.bindenv(this))
            };

            if (step < 0) {
                // negative step, go backwards
                // `skip` will take care of the magnitude of the steps
                objectsStartCodes.seek(-2, 'e');
            }


            local addr, spiAddr, obj, readObj, cont, seekTo;

            // Passed in to the read callback to be called as `next`
            cont = function(keepGoing = true) {
                if (keepGoing == false) {
                    // Clean up and exit
                    objectsStartCodes = obj = null;
                    if (onFinish != null) onFinish();
                } else if ((objectsStartCodes.seek(seekTo, 'c') == -1 || objectsStartCodes.eos() == 1)) {
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
                    addr = objectsStartCodes.readn('w');
                    // Calculate the raw spiflash address
                    spiAddr = _start + sector * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_METADATA_SIZE + addr;
                    // Read the object
                    obj = _getObject(spiAddr);

                    // If we're moving backwards, do so, otherwise our blob cursor is
                    // already moved forward by reading
                    if (step < 0) seekTo = -4;
                    else seekTo = 0

                    return onData(obj, spiAddr, cont.bindenv(this));

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

    // Erases all dirty sectors, or an individual object
    // This method erases an object at SPIFlash address address by marking it erased.
    // If address is not specified, it behaves as eraseAll() method with the default parameter.
    function erase(addr = null) {
        if (addr == null) return eraseAll();
        else return _eraseObject(addr);
    }

    // Erases the entire allocated SPIFlash area.
    // The optional force parameter is a Boolean value which defaults to false,
    // a value which will cause the method to erase only the sectors
    // written to by this library. You must pass in true
    // if you wish to erase the entire allocated SPIFlash area.
    // Parametes:
    //    force - force all sectors erase, otherwise only dirty
    function eraseAll(force = false) {
        for (local sector = 0; sector < _sectors; sector++) {
            if (force || _map[sector] == SPIFLASHLOGGER_SECTOR_DIRTY) {
                _erase(sector);
            }
        }
    }

    //
    // This method returns the current SPI flash pointer,
    // ie. where the SPIFlashLogger will perform the next write operation.
    // This information can be used along with the setPosition()
    // method to optimize SPIFlash memory usage between deep sleeps.
    //
    function getPosition() {
        // Return the current pointer (sector + offset)
        return _atSec * SPIFLASHLOGGER_SECTOR_SIZE + _atPos;
    }

    //
    // This method sets the current SPI flash pointer,
    // ie. where the SPIFlashLogger will perform the next read/write operation.
    // Setting the pointer can help optimize SPI flash memory usage
    // between deep sleeps, as it allows the SPIFlashLogger to be precise
    // to one byte rather 256 bytes (the size of a chunk).
    function setPosition(position) {
        // Grab the sector and offset from the position
        local sector = position / SPIFLASHLOGGER_SECTOR_SIZE;
        local offset = position % SPIFLASHLOGGER_SECTOR_SIZE;

        // Validate sector and position
        if (sector < 0 || sector >= _sectors) throw "Position out of range";

        // Set the current sector and position
        _atSec = sector;
        _atPos = offset;
    }

    //
    // Enable flash lock
    //
    function _enable() {
        // Check _enables then increment
        if (_enables == 0) {
            _flash.enable();
        }

        _enables += 1;
    }

    //
    // Disable flash lock
    //
    function _disable() {
        // Decrement _enables then check
        _enables -= 1;

        if (_enables == 0)  {
            _flash.disable();
        }
    }

    //
    // Increase sector id and check id overflow
    //
    function _getNextSectorId() {
        if (_nextSectorId <= 0)
            _nextSectorId = 1;
        return _nextSectorId++;
    }

    //
    // Gets the logged object at the specified position
    //
    function _getObject(pos, cb = null) {
        local requested_pos = pos;

        _enable();
        // Get the meta (for checking) and the object length (to know how much to read)
        local marker = _flash.read(pos, SPIFLASHLOGGER_OBJECT_MARKER_SIZE).tostring();
        local len = _flash.read(pos + SPIFLASHLOGGER_OBJECT_MARKER_SIZE, 2).readn('w');
        _disable();

        if (marker != SPIFLASHLOGGER_OBJECT_MARKER) {
            throw "Error, marker not found at " + pos;
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

            if (pos == _end) pos = _start + SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
            else if (pos == sectorEnd) pos += SPIFLASHLOGGER_SECTOR_METADATA_SIZE;

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

    // Returns a blob of 16 bit address of starts of objects,
    // relative to sector body start
    //
    function _getObjectsStartCodesForSector(sector_idx) {
        local from = 0,        // index to search form
              addrs = blob(),  // addresses of starts of objects
              found;

        // Sector clean
        if (_map[sector_idx] != SPIFLASHLOGGER_SECTOR_DIRTY) return addrs;

        local dataStart = _start + sector_idx * SPIFLASHLOGGER_SECTOR_SIZE + SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
        local readLength = SPIFLASHLOGGER_SECTOR_BODY_SIZE;
        _enable();
        local sectorData = _flash.read(dataStart, readLength).tostring();
        _disable();
        if (sectorData == null) return addrs;

        while ((found = sectorData.find(SPIFLASHLOGGER_OBJECT_MARKER, from)) != null) {
            // Found an object start, save the address
            addrs.writen(found, 'w');
            // Skip the one we just found the next time around
            from = found + 1;
        }

        addrs.seek(0);
        return addrs;
    }

    //
    // Write full object or object part
    //
    function _write(object, sector, pos, objectPos = 0, len = null) {
        if (len == null) len = object.len();

        // Prepare the new metadata
        local meta = blob(6);

        // Erase the sector(s) if it is dirty but not if we are appending
        local appending = (pos > SPIFLASHLOGGER_SECTOR_METADATA_SIZE);
        if (_map[sector] == SPIFLASHLOGGER_SECTOR_DIRTY && !appending) {
            // Prepare the next sector
            _erase(sector, sector+1, true);
            // Write a new sector id
            meta.writen(_getNextSectorId(), 'i');
        } else {
            // Make sure we have a valid sector id
            if (_getSectorMetadata(sector).id > 0) {
                meta.writen(0xFFFFFFFF, 'i');
            } else {
                meta.writen(_getNextSectorId(), 'i');
            }
        }

        // Write the new usage map, changing only the bit in this write
        local chunkMap = 0xFFFF;
        local bitStart = math.floor(1.0 * pos / SPIFLASHLOGGER_CHUNK_SIZE).tointeger();
        local bitFinish = math.ceil(1.0 * (pos+len) / SPIFLASHLOGGER_CHUNK_SIZE).tointeger();
        for (local bit = bitStart; bit < bitFinish; bit++) {
            local mod = 1 << bit;
            chunkMap = chunkMap ^ mod;
        }
        meta.writen(chunkMap, 'w');

        // Write the metadata and the data
        local start = _start + (sector * SPIFLASHLOGGER_SECTOR_SIZE);
        _enable();
        _flash.write(start, meta, SPIFLASH_POSTVERIFY);
        local res = _flash.write(start + pos, object, SPIFLASH_POSTVERIFY, objectPos, objectPos + len);
        _disable();

        if (res != 0) {
            throw format("Writing failed from object position %d of %d, to 0x%06x (meta), 0x%06x (body)", objectPos, len, start, start + pos)
            return null;
        } else {
            // server.log(format("Written to: 0x%06x (meta), 0x%06x (body) of: %d", start, start + pos, objectPos));
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

    //
    // Read sector metadata
    //
    function _getSectorMetadata(sector) {
        // NOTE: Should we skip clean sectors automatically?
        _enable();
        local start = _start + (sector * SPIFLASHLOGGER_SECTOR_SIZE);
        local meta = _flash.read(start, SPIFLASHLOGGER_SECTOR_METADATA_SIZE);
        // Parse the meta data
        meta.seek(0);
        _disable();

        return { "id": meta.readn('i'), "map": meta.readn('w') };
    }

    //
    // Count the number of dirty chunks in sector
    //
    function _dirtyChunkCount(sector) {
        local map = _getSectorMetadata(sector).map;
        local count, mask;
        for (count = 0, mask = 0x0001; mask < 0x8000; mask = mask << 1) {
            if (!(map & mask)) count++;
            else break;
        }
        return count+1;// TODO: why was this plus one necessary?
    }

    //
    // Initialise logger in scope of the provided logger addresses
    //
    function _init() {
        local firstSector = {"id" : 0, "sec" : 0, "map": 0xFFFF}; // The smallest id
        local lastSector = {"id" : 0, "sec" : 0, "map": 0xFFFF};// The highest id
        // Read all the metadata
        _enable();
        for (local sector = 0; sector < _sectors; sector++) {
            // Hunt for the highest id and its map
            local meta = _getSectorMetadata(sector);

            if (meta.id > 0) {
                // identify last sector
                if (meta.id > lastSector.id)
                    lastSector = {"id" : meta.id, "sec" : sector, "map": meta.map};
                // identify first sector
                if (firstSector.id == 0 || meta.id < firstSector.id)
                    firstSector = {"id" : meta.id, "sec" : sector, "map": meta.map};

            } else {
                // This sector has no id, we are going to assume it is clean
                _map[sector] = SPIFLASHLOGGER_SECTOR_CLEAN;
            }
        }
        _disable();

        // handle ID overflow use-case
        if (lastSector.id - firstSector.id >= (0x7FFFFFFF - _sectors))
            lastSector = firstSector;

        _atPos = 0;
        _atSec = lastSector.sec;
        _nextSectorId = lastSector.id;
        // increase sector id
        _getNextSectorId();
        for (local bit = 1; bit <= 16; bit++) {
            local mod = 1 << bit;
            _atPos += (~lastSector.map & mod) ? SPIFLASHLOGGER_CHUNK_SIZE : 0;
        }
    }

    //
    //  Erase sector part
    //
    function _erase(startSector = null, endSector = null, preparing = false) {
        if (startSector == null) {
            startSector = 0;
            endSector = _sectors;
        }

        if (endSector == null) {
            endSector = startSector + 1;
        }

        if (startSector < 0 || endSector > _sectors) throw "Invalid format request";

        _enable();
        for (local sector = startSector; sector < endSector; sector++) {
            // Erase the requested sector
            _flash.erasesector(_start + (sector * SPIFLASHLOGGER_SECTOR_SIZE));
            // server.log(format("Erasing: %d (0x%04x)", sector, _start + (sector * SPIFLASHLOGGER_SECTOR_SIZE)));

            // Mark the sector as clean
            _map[sector] = SPIFLASHLOGGER_SECTOR_CLEAN;

            // Move the pointer on to the next sector
            if (!preparing && sector == _atSec) {
                _atSec = (_atSec + 1) % _sectors;
                _atPos = SPIFLASHLOGGER_SECTOR_METADATA_SIZE;
            }
        }
        _disable();
    }
}
