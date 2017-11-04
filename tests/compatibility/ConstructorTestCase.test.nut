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
class ConstructorTestCase extends Core {
  _postfix = " - 09876543210987654321098765432109876543210987654321";
  _maxLogsInSector = 62; // Max logs which could fit in one sector

  // Test the logger recovery scenarious
  // It should be possible to recover the writing position
  // to the almost the same place (rounded to the chunk size)
  // And user could keep on writing and reading object after logger
  // restore (creation a new instance of logger at the same sectors)
  // Test scenarious:
  //   First logger is writing data into the 1-st sectors
  //   The second logger recovers position which is rounded to chunk size
  //       but it is point to the sector end position
  //   Check that we can read the previous values
  //   Check that we can write one more value
  //   Check that we can read after write and nothing changed
  function testConstructorRecovery() {
      local start = 0;
      local end = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
      // Initialize 2 sectors logger
      local logger = SPIFlashLogger(start, end);
      // Clear all previous data
      logger.eraseAll(true);
      // Fill first sector with maximium objects
      for (local i = 0; i <= _maxLogsInSector; i++) {
          logger.write(i + _postfix);
      }

      // Save curren position and free current
      // logger to initialize a new one
      local position = logger.getPosition();
      logger = null;
      // Initialize another logger on the same sectors
      // to check position recovery process on logger initialization
      local logger2 = SPIFlashLogger(start, end);
      // A new position should at the same address or chunk rounded
      assertTrue(logger2.getPosition() >= position);
      // Check position after recovery (it should be chunk rounded)
      assertEqual(logger2.getPosition() - position < SPIFLASHLOGGER_CHUNK_SIZE,
          true, "Wrong position.");
      assertEqual(_maxLogsInSector + _postfix, logger2.last(), "Failed to read data after recovery");

      // Check writing data after recovery
      local testObj = "Some comment in a new position";
      logger2.write(testObj);
      // Check that it is possible to keep on writing after recovery
      assertEqual(testObj, logger2.last(), "Failed to write after recovery");
      // Check sync read from the previous sector
      assertEqual(_maxLogsInSector + _postfix, logger2.readSync(-2), "Failed to read data after recovery");
  }

  // this test is similar to the previous one
  // but with one major difference that
  // first logger write down data into the second sector
  // but startcode of the last payload is located in
  // the first sector
  function testConstructorRecoveryWithSecondSector() {
      local start = 0;
      local end = 2 * SPIFLASHLOGGER_SECTOR_SIZE;
      // Initialize 2 sectors logger
      local logger = SPIFlashLogger(start, end);
      logger.eraseAll();
      // Fill first logger sector with objects
      // and write one more log to allocate next sector
      // for writing
      for (local i = 0; i <= _maxLogsInSector + 1; i++) {
          logger.write(i + _postfix);
      }
      // Save posisiton and free logger
      local position = logger.getPosition();
      logger = null;
      // Initialize a new logger instance
      local logger2 = SPIFlashLogger(start, end);
      // Check position after recovery (it should be chunk rounded)
      assertTrue(logger2.getPosition() >= position,
          "Wrong recovery position");
      assertTrue(logger2.getPosition() - position < SPIFLASHLOGGER_CHUNK_SIZE,
          "Wrong position.");
      assertEqual((_maxLogsInSector + 1) + _postfix, logger2.last(),
          "Failed to read data after recovery");

      // Check writing data after recovery
      local testObj = "Some comment in a new position";
      logger2.write(testObj);
      // Check that it is possible to write at recovered position
      // after logger re-init
      assertEqual(testObj, logger2.last(), "Failed to write after recovery");
      // Check sync read from the previous sector
      assertEqual((_maxLogsInSector + 1) + _postfix, logger2.readSync(-2),
          "Failed to read data after recovery");
  }
}
