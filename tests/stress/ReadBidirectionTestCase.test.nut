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

// Test read forward and backward
// Tests for SPIFlashLogger
class ReadBidirectionTestCase extends Core {

    _logger = null;

    function setUp() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) return reject("Cannot run tests, missing hardware.spiflash");

                local start = getRandomSectorStart(2);
                local end   = start + 2;
                start *= SPIFLASHLOGGER_SECTOR_SIZE;
                end   *= SPIFLASHLOGGER_SECTOR_SIZE;
                _logger = SPIFlashLogger(start, end);
                
                _logger.erase();
                for (local i = 0; i < 500; i++) {
                    _logger.write(i);
                }

                return resolve();
            } catch (ex) {
                return reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }

    function testReadForwardsAndBackwards() {
        return Promise(function(resolve, reject) {
            if (!isAvailable()) return reject("Cannot run test, missing hardware.spiflash");

            local isOneReadingComplete = false;
            // READ FORWARD
            local expectedFwd = 0;
            _logger.read(function(data, addr, next) {
                try {
                    assertEqualWrap(expectedFwd, data, "Wrong data");
                    expectedFwd += 1;
                    next();
                } catch (ex) {
                    // No need to reject twice
                    if (!isOneReadingComplete) {
                        reject(ex);
                        isOneReadingComplete = true;
                    }
                    next(false);
                }
            }.bindenv(this), function() {
                if (!isOneReadingComplete) {
                    isOneReadingComplete = true;
                    resolve();
                }
            }.bindenv(this));

            // READ BACKWARDS
            local expectedBwd = 499;
            _logger.read(function(data, addr, next) {
                try {
                    assertEqualWrap(expectedBwd, data, "Wrong data");
                    expectedBwd -= 1;
                    next();
                } catch (ex) {
                    if (!isOneReadingComplete) {
                        reject(ex);
                        isOneReadingComplete = true;
                    }
                    next(false);
                }
            }.bindenv(this), function() {
                if (!isOneReadingComplete) {
                    isOneReadingComplete = true;
                    resolve();
                }
            }.bindenv(this), -1);
        }.bindenv(this));
    } // Bi-Direction reading
}
