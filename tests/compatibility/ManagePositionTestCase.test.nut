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

// ManagePositionTestCase
// Tests for SPIFlashLogger.getPosition() and setPosition(position)
class ManagePositionTestCase extends Core {

    function testBasic() {
        return Promise(function(resolve, reject) {
            if (!isAvailable()) {
                resolve();
                return;
            }
            local start = 0;
            local end = SPIFLASHLOGGER_SECTOR_SIZE;
            local logger = SPIFlashLogger(start, end);
            logger.erase();
            logger.setPosition(0);
            // fill logger with values 1 2 3 and then compare length and position
            local length = SPIFLASHLOGGER_SECTOR_META_SIZE;
            for (local i = 0; i < 3; i++) {
                logger.write(i);
                length += Serializer.sizeof(i, SPIFLASHLOGGER_OBJECT_MARKER);
            }
            try {
                assertDeepEqualWrap(length, logger.getPosition(), "Wrong getPosition() value");
            } catch (ex) {
                reject(ex);
                return;
            }
            // set position to 0, so values will be overriden
            local loggerNew = SPIFlashLogger(start, end);
            loggerNew.setPosition(0);
            local overrideFrom = 5;
            local overrideTo = 8;
            for (local i = overrideFrom; i < overrideTo; i++) {
                loggerNew.write(i);
            }
            // check that the values have been overridden (because of setPosition(0) method)
            loggerNew.read(function(data, addr, next) {
                try {
                    if (data >= overrideTo) throw "Read value more than '" + overrideTo + "'";
                    assertDeepEqualWrap(overrideFrom++, data, "Data have not been overridden");
                    next();
                } catch (ex) {
                    reject(ex);
                }
            }.bindenv(this), resolve);
        }.bindenv(this));
    }
}
