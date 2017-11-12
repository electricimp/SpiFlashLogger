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

// WriteTillOverrideTestCase
// Tests for SPIFlashLogger.write()
class WriteTillOverrideTestCase extends Core {

    function testFirstSectorOverride() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }
                local start = 0;
                local end = SPIFLASHLOGGER_SECTOR_SIZE;
                // one sector logger
                local logger = SPIFlashLogger(start, end, null, Serializer);
                logger.eraseAll(true);
                local message = 1;
                local messageDifferent = 2;
                local messagesPerSector =
                     (SPIFLASHLOGGER_SECTOR_SIZE - SPIFLASHLOGGER_SECTOR_METADATA_SIZE) / Serializer.sizeof(message, SPIFLASHLOGGER_OBJECT_MARKER);
                for (local i = 0; i < messagesPerSector + 1; i++) {
                    if (i < messagesPerSector) {
                        logger.write(message);
                    } else {
                        logger.write(messageDifferent);
                    }
                }
                local hasData = false;
                logger.read(function(data, addr, next) {
                    hasData = true;
                    try {
                        assertEqualWrap(messageDifferent, data, "Wrong data");
                        resolve();
                    } catch (ex) {
                        reject(ex);
                    }
                    next(false);
                }.bindenv(this), function() {
                  if (!hasData)
                      reject();
                }.bindenv(this));
            } catch (ex) {
                reject("Unexpected error: " + ex);
            }
        }.bindenv(this));
    }
}
