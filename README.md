# SPIFlashLogger 1.0.0

The SPIFlashLogger manages all or a portion of a SPI flash (either via imp003+'s built-in [hardware.spiflash](https://electricimp.com/docs/api/hardware/spiflash) or any functionally compatible driver such as the [SPIFlash library](https://github.com/electricimp/spiflash)).

The SPIFlashLogger creates a circular log system, allowing you to log any serializable object (table, array, string, blob, integer, float, boolean and null) to the SPIFlash. If the log systems runs out of space in the SPIFlash, it begins overwritting the oldest logs.

**To add this library to your project, add `#require "SPIFlashLogger.class.nut:1.0.0"`` to the top of your device code.**

You can view the library’s source code on [GitHub](https://github.com/electricimp/spiflashlogger/tree/v1.0.0).

## Memory Efficiency
The SPIFlash logger operates on 4Kb sectors, and 256 byte chunks. Some necessary overhead is added to the beginning of each sector, as well as each serialized object (assuming you are using the standard [Serializer library](http://github.com/electricimp/serializer)). The overhead includes:

- 256 bytes of every sector are expended on metadata.
- A four byte marker is added to the beginning of each serialized object to aid in locating objects in the datastream.
- The *Serializer* object also adds some overhead to each object (see the [Serializer's documentation](https://github.com/electricimp/serializer/tree/master/README.md) for more information).
- After a reboot the sector meta data allows the class to locate the next write position at the next chunk which wastes some of the previous chunk (this behaviour can be overrideen using the *getPosition* and *setPosition* methods).

## Class Usage

### Constructor: SPIFlashLogger([start, end, spiflash, serializer])

The SPIFlashLogger's constructor takes 4 optional parameters:

| parameter  | default           | description |
| ---------- | ----------------- | ----------- |
| start      | 0                 | The first byte in the SPIFlash to use (must be the first byte of a sector). |
| end        | spiflash.size()   | The last byte in the SPIFlash to use (must be the last byte of a sector). |
| spiflash   | hardware.spiflash | hardware.spiflash, or an object with an equivalent interface such as the [SPIFlash](https://github.com/electricimp/spiflash) library. |
| serializer | Serializer        | The static [Serializer library](https://github.com/electricimp/serializer), or an object with an equivalent interface. |

```squirrel
// Initializing a SPIFlashLogger on an imp003+
#require "Serialier.class.nut:1.0.0"
#require "SPIFlashLogger.class.nut:1.0.0"

// Initialize Logger to use the entire SPI Flash
logger <- SPIFlashLogger();
```

```squirrel
// Initializing a SPIFlashLogger on an imp002
#require "Serialier.class.nut:1.0.0"
#require "SPIFlash.class.nut:1.0.0"
#require "SPIFlashLogger.class.nut:1.0.0"

// Setup SPI Bus
spi <- hardware.spi257;
spi.configure(CLOCK_IDLE_LOW | MSB_FIRST, 30000);

// Setup Chip Select Pin
cs <- hardware.pin8;
spiFlash <- SPIFlash(spi, cs);

// Initialize the logger object using the entire SPIFlash
logger <- SPIFlashLogger(null, null, spiFlash);
```

## Class Methods

### dimensions()
The *dimensions* method returns a table with the following keys:

```squirrel
{
    "size" :        integer,    // The size of the SPIFlash in bytes
    "len" :         integer,    // Number of bytes allocated to the logger
    "start" :       integer,    // First byte used by the logger
    "end" :         integer,    // Last byte used by the logger
    "sectors" :     integer,    // Number of sectors allocated to the logger
    "sector_size" : integer     // Size of sectors in bytes
}
```

### write(object)

Writes any serializable object to the memory allocated to the SPIFlashLogger. If the memory is full, the logger will begin overwritting the oldest entries.

```squirrel
function readAndSleep() {
    // Read and log the data..
    local data = getData();
    logger.log(data);

    // Go to sleep for an hour
    imp.onidle(function() { server.deepsleepfor(3600); });
}
```

### readSync(onDatapoint)

The *readSync* method performs a synchronous read of *ALL* logs that are currently stored, and invokes the *onDatapoint* callback for each (in the order they were logged).

```squirrel
function sendToAgent() {
    local data = [];
    logger.readSync(function(dataPoint) {
        // Push each datapoint into the data array
        data.push(datapoint);
    });

    agent.send("data", data);
    logger.erase();
}
```

### erase()

Erasing all memory allocated to the SPIFlash logger. See *readSync* for example usage.

### getPosition(sector, offset)

The *getPosition* method returns the current sector and offset pointers (i.e. where the SPIFlashLogger will perform the next read). This information can be used along with the *setPosition* method to optimize SPIFlash memory usage between deepsleeps.

```squirrel
// Create the logger object
logger <- SPIFlashLogger();

// Check if we have position information in the nv table:
if ("nv" in getroottable() && "position" in nv) {
    // If we do, update the position pointers in the logger object
    logger.setPosition(nv.position.sector, nv.position.offset);
} else {
    // If we don't, grab the position points and set nv
    local position = logger.getPosition();
    nv <- {
        "position": {
                "sector": positionData.sector,
                "offset": positionData.offset
           }
       }
    };
}

// Get some data and log it
data <- getData();
logger.log(data);

// Increment a counter
if (!("count" in nv)) nv.count <- 1;
else nv.count++;

// If we have more than 100 samples
if (nv.count > 100) {
    // Send the samples to the agent
    sendToAgent();
}

// Go to sleep
imp.onidle(function() {
    // Get and store position pointers for next run
    local position = logger.getPosition();
    nv.position <- {
        "sector": position.sector,
        "offset": position.offset
    };

    // Sleep for 1 minute
    imp.deepsleepfor(60);
});
```

# License

The SPIFlashLogger class is licensed under [MIT License](https://github.com/electricimp/spiflashlogger/tree/master/LICENSE).
