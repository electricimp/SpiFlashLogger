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

// OverflowTestCase
// Tests for SPIFlashLogger
class SectorIdOverflowTestCase extends Core {

    function testSectorIdOverflow() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) return reject("Cannot run test, missing hardware.spiflash");

                local sectors = 5;
                local start   = 0;
                local end     = start + sectors;
                local logger  = SPIFlashLogger(start * SPIFLASHLOGGER_SECTOR_SIZE, end * SPIFLASHLOGGER_SECTOR_SIZE);
                
                logger.eraseAll(true);
                logger._nextSectorId = 0x7FFFFFFE;
                for (local i = 0; i < 400; i++) {
                    logger.write(i);
                }

                assertTrue(logger._nextSectorId < sectors, "Failed to handle next sector id overflow");
                local logger2  = SPIFlashLogger(start * SPIFLASHLOGGER_SECTOR_SIZE, end * SPIFLASHLOGGER_SECTOR_SIZE);
                // Check the position correctly recovered
                assertTrue(logger2.getPosition() - logger.getPosition() >= 0, "Wrong position recovery in case of overflow.");
                // Check an internal counter recovery
                assertEqual(logger2._nextSectorId, logger._nextSectorId, "Wrong sector id after recovery");
                return resolve();
            } catch (ex) {
                return reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }
}
