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

// ErasureTestCase
// Tests for SPIFlashLogger.erase() and eraseAll()
class ErasureTestCase extends Core {

    function testReadEraseReadSequence() {
        if (!isAvailable()) {
            return;
        }
        local start = math.rand() % 15;
        local end = start + 1;
        start *= SPIFLASHLOGGER_SECTOR_SIZE;
        end   *= SPIFLASHLOGGER_SECTOR_SIZE;
        local logger = SPIFlashLogger(start, end);
        logger.erase();
        for (local i = 1; i <= 5; i++) {
            logger.write(i);
        }
        return Promise(function(resolve, reject) {
            local expected = 0;
            logger.read(function(data, addr, next) {
                try {
                    assertDeepEqualWrap(++expected, data, "Wrong data");
                    logger.erase(addr);
                    next();
                } catch (ex) {
                    reject(ex);
                    next(false);
                }
            }.bindenv(this), resolve);
        }.bindenv(this))
        .then(function(_) {
            return Promise(function(resolve, reject) {
                logger.read(function(data, addr, next) {
                    reject("Data was not erased");
                    next(false);
                }.bindenv(this), resolve);
            }.bindenv(this));
        }.bindenv(this));
    }

    function testEraseAll() {
        return Promise(function(resolve, reject) {
            if (!isAvailable()) {
                resolve();
                return;
            }
            local start = math.rand() % 15;
            local end = start + 1;
            start *= SPIFLASHLOGGER_SECTOR_SIZE;
            end   *= SPIFLASHLOGGER_SECTOR_SIZE;
            local logger = SPIFlashLogger(start, end);
            logger.erase();
            for (local i = 1; i <= 5; i++) {
                logger.write(i);
            }
            logger.eraseAll();
            logger.read(function(data, addr, next) {
                reject("Data was not erased");
                next(false);
            }.bindenv(this), resolve);
        }.bindenv(this));
    }
}
