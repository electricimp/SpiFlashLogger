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

@include "github:electricimp/Serializer/Serializer.class.nut"

class Core extends ImpTestCase {

    function isAvailable() {
        local available = "spiflash" in hardware;
        if (!available) info("Test hardware missing hardware.spiflash");
        return available;
    }

    function getRandomSectorStart(endOffset = 1) {
        hardware.spiflash.enable();
        local sectorsCount = hardware.spiflash.size() / SPIFLASHLOGGER_SECTOR_SIZE;
        hardware.spiflash.disable();

        local maxStart = sectorsCount - endOffset;
        return (1.0 * maxStart * math.rand() / RAND_MAX).tointeger();
    }

    function assertEqualWrap(expected, actual, message = null, annotate = true) {
        if (annotate) {
            local annotateString = "Expected: '" + expected + "'. " +
                                   "Actual: '" + actual + "'.";
            if (message == null) {
                message = annotateString;
            } else {
                message = message + ". " + annotateString;
            }
        }
        assertEqual(expected, actual, message);
    }
}
