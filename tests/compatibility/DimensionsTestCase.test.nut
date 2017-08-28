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

// DimensionsTestCase
// Tests for SPIFlashLogger.dimensions()
class DimensionsTestCase extends Core {

    function testBasic() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                hardware.spiflash.enable();
                local size = hardware.spiflash.size();
                hardware.spiflash.disable();
                local logger = SPIFlashLogger();
                local dimensions = logger.dimensions();
                try {
                    assertDeepEqualWrap(0, dimensions.start, "dimensions.start");
                    assertDeepEqualWrap(size, dimensions.end, "dimensions.end");
                    assertDeepEqualWrap(size, dimensions.len, "dimensions.len");
                    assertDeepEqualWrap(size, dimensions.size, "dimensions.size");
                } catch (ex) {
                    reject(ex);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }

    function testWithStart() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                local start = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
                hardware.spiflash.enable();
                local size = hardware.spiflash.size();
                hardware.spiflash.disable();
                local logger = SPIFlashLogger(start);
                local dimensions = logger.dimensions();
                try {
                    assertDeepEqualWrap(start, dimensions.start, "dimensions.start");
                    assertDeepEqualWrap(size, dimensions.end, "dimensions.end");
                    assertDeepEqualWrap(size - start, dimensions.len, "dimensions.len");
                    assertDeepEqualWrap(size, dimensions.size, "dimensions.size");
                } catch (ex) {
                    reject(ex);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }

    function testWithEnd() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                local end = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
                hardware.spiflash.enable();
                local size = hardware.spiflash.size();
                hardware.spiflash.disable();
                local logger = SPIFlashLogger(null, end);
                local dimensions = logger.dimensions();
                try {
                    assertDeepEqualWrap(0, dimensions.start, "dimensions.start");
                    assertDeepEqualWrap(end, dimensions.end, "dimensions.end");
                    assertDeepEqualWrap(end, dimensions.len, "dimensions.len");
                    assertDeepEqualWrap(size, dimensions.size, "dimensions.size");
                } catch (ex) {
                    reject(ex);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }

    function testWithStartAndEnd() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                local start = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
                local end = 8 * SPIFLASHLOGGER_SECTOR_SIZE;
                hardware.spiflash.enable();
                local size = hardware.spiflash.size();
                hardware.spiflash.disable();
                local logger = SPIFlashLogger(start, end);
                local dimensions = logger.dimensions();
                try {
                    assertDeepEqualWrap(start, dimensions.start, "dimensions.start");
                    assertDeepEqualWrap(end, dimensions.end, "dimensions.end");
                    assertDeepEqualWrap(end - start, dimensions.len, "dimensions.len");
                    assertDeepEqualWrap(size, dimensions.size, "dimensions.size");
                } catch (ex) {
                    reject(ex);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }
}
