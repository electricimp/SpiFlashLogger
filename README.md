SPI Flash Logger class
======================

Introduction
------------

The SPI Flash Logger class manages all or a portion of a SPI flash (either via imp003+'s built-in SPI flash driver or any functionally compatible driver) and turns it into an logger. It will log any serialisable object (table, array, string, blob, integer, float, boolean and null) and when it reaches the end of the available space it will override the oldest data first. 

NOR-flash technology
--------------------

The SPI flash uses NOR technology. This means that all bits are 1 at their initial value (or after erasing) and can be changed to 0 with a write command. Once a bit has been changed to 0 it will remain there until it is erased. Further writes have no effect, similarly writing a 1 never has any effect. Reads and writes are unlimited and reliable but erase actions are limited to somewhere between 100,000 and 1,000,000 erases on any one sector. For this reason, it is best to try to distribute erases over the storage space as much as possible to avoid hot-spots.

Format
------

The physical memory is usually divided into blocks (64kb) and sectors (4kb) and the class adds a concept of chunks (256 bytes). This class ignores blocks and works with sector and chunks but all erases are performed one sector at a time. At the start of every sector use the first chunk to store meta data about the sector, specifically a four-byte sector id and a two bytes chunk map. In memory the class tracks the exact position of the next write but if the device reboots (and loses this location) the sector meta data is use to rebuild this value to the closest chunk.

Efficiency
----------

- 256 bytes of every sector are expended on meta data.
- Serialisation of the object has some overhead dependant on the object structure. The serialised object contains length and CRC meta data.
- There is a four byte marker before every object to help locate the start of each object in the data stream.
- After a reboot the sector meta data allows the class to locate the next write position at the next chunk which wastes some of the previous chunk.
- Write and read operations need to operate a sector at a time because of the meta data at the start of each sector.

Class Methods
-------------

constructor([start [, end [, flash]])

- start = the byte location of the start of the file system. Defaults to 0. Must be on a sector boundary.
- end = the byte location of the end of the file system + 1. Defaults to the size of the storage. Must be on a sector boundary.
- flash = a initialised SPIFlash object. If not provided the internal hardware.spiflash object will be used.

dimensions() 

- returns the size, in bytes, of the storage

write(object)

- object = any serialisable object not larger than the storage space (less the overhead)
- returns nothing

readSync(callback)

- callback = function which will be called once for every object found on the flash. It will be called from the oldest to the newest.
- returns nothing

erase()

- returns nothing

