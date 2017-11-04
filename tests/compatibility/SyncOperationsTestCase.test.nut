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
class SyncOperationsTestCase extends Core {

    logger = null;
    _postfix = " - 09876543210987654321098765432109876543210987654321";
    _maxLogsInSector = 62;

    function setUp() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                local start = 0;
                local end = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
                // Initialize 2 sectors logger
                logger = SPIFlashLogger(start, end);
                // Erase all data
                logger.eraseAll(true);
                // Write max logs to the first sector
                for (local i = 0; i <= _maxLogsInSector; i++) {
                    logger.write(i + _postfix);
                    server.log(i);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error on test setup: " + ex);
            }
        }.bindenv(this));
    }

    function _checkFirstLastAndReadSync(vstart, vend, error) {
        // Check first and last
        assertEqual(vstart + _postfix, logger.first(), error + "Unexpected first log");
        assertEqual(vend + _postfix, logger.last(), error + "Unexpected last log");
        // minimal test of the readSync
        assertEqual((1 + vstart) + _postfix, logger.readSync(2), error + "Unexpected 2-nd log value");
        assertEqual((vend - 1) + _postfix, logger.readSync(-2), error + "Unexpected minus 2-nd log value");
    }

    function testReadSync() {
        // Check first sector
        assertEqual(logger.getPosition() < logger._start + SPIFLASHLOGGER_SECTOR_SIZE, true, "Wrong logger position");
        // check reading in scope of one sector
        _checkFirstLastAndReadSync(0, _maxLogsInSector, "One sector test.");
        // cross sector border: last object between two sectors
        logger.write((_maxLogsInSector + 1) + _postfix);
        // Check that sector border was crossed
        assertEqual(logger.getPosition() > logger._start + SPIFLASHLOGGER_SECTOR_SIZE, true);
        // Check values after sector border crossing
        _checkFirstLastAndReadSync(0, _maxLogsInSector + 1, "Two sectors border test.");
        // cross sector border
        logger.write((_maxLogsInSector + 2) + _postfix);
        // last object in the second sector
        _checkFirstLastAndReadSync(0, _maxLogsInSector + 2, "Two sectors test.");
        // rewrite first sector
        for (local i = 3; i <= _maxLogsInSector + 10; i++) {
            logger.write((_maxLogsInSector + i) + _postfix);
        }
        // Check first sector position
        assertEqual(logger.getPosition() < logger._start + SPIFLASHLOGGER_SECTOR_SIZE, true);
        // Test values
        _checkFirstLastAndReadSync(_maxLogsInSector + 1,
            2 * _maxLogsInSector + 10, "Sector overwrite test.");
    }
}
