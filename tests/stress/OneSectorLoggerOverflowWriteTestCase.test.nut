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
// "Promise" symbol is injected dependency from ImpUnit_Promise module,
// while class being tested can be accessed from global scope as "::Promise".

@include __PATH__+"/../Core.nut"

// ReadOneSectorTestCase
// Tests for SPIFlashLogger.read()
class OneSectorLoggerOverflowWriteTestCase extends Core {

    logger = null;
    _postfix = " - 09876543210987654321098765432109876543210987654321";
    _counterShift = 100;  // this shift allow us to have fixed size of objects on write
    _maxLogsInSector = 0; // The maximu logs

    function setUp() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }

                // Calculate the max count of the test-logs which could fit in one sector
                // Test log consists of  index + postfix, but index was shift on _counterShift
                // to have fixed size of the serialised object
                // In the current implementaion: objSize == 66 bytes and maxLogsInSector = 61
                // and sector has 61*66 = 4026 (+ 6 bytes - sector start code)
                local objSize = Serializer.sizeof((_counterShift + _postfix), SPIFLASHLOGGER_OBJECT_MARKER);
                _maxLogsInSector = (SPIFLASHLOGGER_SECTOR_SIZE - SPIFLASHLOGGER_SECTOR_METADATA_SIZE)/ objSize;

                local start = 0;
                local end = SPIFLASHLOGGER_SECTOR_SIZE;
                // Initialize 2 sectors logger
                logger = SPIFlashLogger(start, end);
                // Erase all data
                logger.eraseAll(true);
                // Write max logs to the first sector
                for (local i = 1; i <= _maxLogsInSector; i++) {
                    logger.write((_counterShift + i) + _postfix);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error on test setup: " + ex);
            }
        }.bindenv(this));
    }

    function _checkFirstLastAndReadSync(vstart, vend, error, hasSecondValues = true) {
        // Check first and last
        assertEqual((_counterShift + vstart) + _postfix, logger.first(), error + "Unexpected first log");
        assertEqual((_counterShift + vend) + _postfix, logger.last(), error + "Unexpected last log");
        // minimal test of the readSync
        if (hasSecondValues) {
            assertEqual((_counterShift + 1 + vstart) + _postfix, logger.readSync(2), error + "Unexpected 2-nd log value");
            assertEqual((_counterShift + vend - 1) + _postfix, logger.readSync(-2), error + "Unexpected minus 2-nd log value");
        }
        else {
            assertEqual(null, logger.readSync(2), error + "Unexpected 2-nd log value");
            assertEqual(null, logger.readSync(-2), error + "Unexpected minus 2-nd log value");
        }
    }

    function testReadSync() {
        // Check first sector
        assertTrue(logger.getPosition() < logger._start + SPIFLASHLOGGER_SECTOR_SIZE, "Wrong logger position");
        // check reading in scope of one sector
        _checkFirstLastAndReadSync(1, _maxLogsInSector, "First sector write test.");
        // check how handle sector overflow :  it is necessary to clean sector
        // and write down object in the ersaed sector
        logger.write((_counterShift + _maxLogsInSector + 1) + _postfix);
        // Check that sector was erased and object was not damaged
        local position = logger._start   // logger start address
            + SPIFLASHLOGGER_SECTOR_METADATA_SIZE  // sector metadata
            + Serializer.sizeof((_counterShift + _maxLogsInSector + 1) + _postfix,
                SPIFLASHLOGGER_OBJECT_MARKER); // serialized object shifted on obj marker

        assertEqual(logger.getPosition(), position, "Wrong position after sector overwrite");
        // Check values after overwrite
        // the last and the first should be equal
        _checkFirstLastAndReadSync(_maxLogsInSector + 1, _maxLogsInSector + 1, "Two sectors border test.", false);
        // cross sector border
        logger.write((_counterShift + _maxLogsInSector + 2) + _postfix);
        // Check that write is going on correctly
        _checkFirstLastAndReadSync(_maxLogsInSector + 1, _maxLogsInSector + 2, "Two sectors test.");
        // Overwrite sector once more
        for (local i = 3; i <= _maxLogsInSector + 10; i++) {
            logger.write((_counterShift + _maxLogsInSector + i) + _postfix);
        }
        // Check first sector position
        assertEqual(logger.getPosition() < logger._start + SPIFLASHLOGGER_SECTOR_SIZE, true);
        // Test values
        _checkFirstLastAndReadSync(2 * _maxLogsInSector + 1,
            2 * _maxLogsInSector + 10, "Sector overwrite test failed.");
    }
}
