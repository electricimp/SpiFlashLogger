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
// Tests for SPIFlash__logger.read()
class MultipleSectors_loggerOverflowWriteTestCase extends Core {

    _logger = null;
    _someData = " - 09876543210987654321098765432109876543210987654321";

    function setUp() {
        return Promise(function(resolve, reject) {
            try {
                if (!isAvailable()) {
                    resolve();
                    return;
                }

                local start = 0;
                local end = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
                // Initialize 2 sectors _logger
                _logger = SPIFlashLogger(start, end);
                // Erase all data
                _logger.eraseAll(true);

                resolve();
            } catch (ex) {
                reject("Unexpected error on test setup: " + ex);
            }
        }.bindenv(this));
    }

    // An idea of this test is to write object which has size ~1,5 sectors
    // such object should fit into 2 sectors _logger
    // But if we will try to write the same object again then _logger
    // should prevent overwriting of the start code of second object
    function writeMaxSizeObject() {
      // Write max logs to the first sector
      local dataSize = 0;
      local testObj = "";
      while (dataSize < SPIFLASHLOGGER_SECTOR_BODY_SIZE * 3 / 2) {
          testObj += _someData;
          dataSize = Serializer.sizeof(testObj);
      }

      _logger.write(testObj);
      assertTrue(_logger.getPosition() > _logger._start + SPIFLASH_LOGGER_SECTOR_SIZE, "Wrong precondition");
      // it is possible to write only one instance of testObject into the logger
      // Lets try to write object again
      testObj += "K"; // minor changes for the test object
      _logger.write(testObj);
      assertTrue(_logger.getPosition() < _logger._start + SPIFLASH_LOGGER_SECTOR_SIZE, "Expected that logger keep working sector on erase");
      assertEqual(testObj, _logger.first(), "Failed to restore current object");

      testObj += "R"; // minor changes for the test object
      _logger.write(testObj);
      assertTrue(_logger.getPosition() > _logger._start + SPIFLASH_LOGGER_SECTOR_SIZE, "Expected that logger keep working sector on erase");
      assertEqual(testObj, _logger.first(), "Failed to restore current object");
    }
}
