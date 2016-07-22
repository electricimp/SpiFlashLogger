class TestFillErUp extends ImpTestCase {
    _logger = null;

    function setUp() {
        // Do some wear leveling
        local s = math.rand() % 120;
        local e = s + 1; // Assign only one sector
        s*= SPIFLASHLOGGER_SECTOR_SIZE;
        e*= SPIFLASHLOGGER_SECTOR_SIZE;

        _logger = SPIFlashLogger(s, e);
        _logger.erase() // start fresh

        for (local i = 0; i < 682; i++) {
            _logger.write(i);
        }
    }

    // Begin tests

    function testFillErUp() {
        for (local i = 0; i < 1000; i++) {
            _logger.write(i);
        }
    }
}
