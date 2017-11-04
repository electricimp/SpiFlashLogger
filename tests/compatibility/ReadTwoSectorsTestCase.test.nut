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

// ReadTwoSectorsTestCase
// Tests for SPIFlashLogger.read()
class ReadTwoSectorsTestCase extends Core {

    logger = null;

    function setUp() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                local start = math.rand() % 120;
                local end = start + 2;
                start *= SPIFLASHLOGGER_SECTOR_SIZE;
                end   *= SPIFLASHLOGGER_SECTOR_SIZE;
                logger = SPIFlashLogger(start, end);
                logger.erase();
                for (local i = 0; i < 500; i++) {
                    logger.write(i);
                }
                resolve();
            } catch (ex) {
                reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }

    function testReadForwards() {
        return Promise(function(resolve, reject) {
            if (!isAvailable()) {
                resolve();
                return;
            }
            local expected = 0;
            logger.read(function(data, addr, next) {
                try {
                    assertEqualWrap(expected, data, "Wrong data");
                    expected += 1;
                    next();
                } catch (ex) {
                    reject(ex);
                    next(false);
                }
            }.bindenv(this), resolve);
        }.bindenv(this));
    }

    function testByTwos() {
        return Promise(function(resolve, reject) {
            if (!isAvailable()) {
                resolve();
                return;
            }
            local expected = 0;
            logger.read(function(data, addr, next) {
                try {
                    assertEqualWrap(expected, data, "Wrong data");
                    expected += 2;
                    next();
                } catch (ex) {
                    reject(ex);
                    next(false);
                }
            }.bindenv(this), resolve, 2);
        }.bindenv(this));
    }

    function testReadBackwards() {
        return Promise(function(resolve, reject) {
            if (!isAvailable()) {
                resolve();
                return;
            }
            local expected = 499;
            logger.read(function(data, addr, next) {
                try {
                    assertEqualWrap(expected, data, "Wrong data");
                    expected -= 1;
                    next();
                } catch (ex) {
                    reject(ex);
                    next(false);
                }
            }.bindenv(this), resolve, -1);
        }.bindenv(this));
    }
}
