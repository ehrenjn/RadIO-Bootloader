An ATmega328p / ATmega328pb bootloader for @danielj-n's [RadIO project](https://github.com/danielj-n/RadIO/) that allows you to program RadIO over a USB connection  

#### Features:

- Only 512 bytes
	- Leaves room for as much application code as possible
- Built in error detection
	- Detects data overrun and USART frame errors
	- Detects when it is trying to overwrite its own code
	- Verifies uploaded program using a checksum
- Fast
	- Main bottleneck is serial baud which, in theory, can be pushed much higher than other ATmega bootloaders



## Usage

### First time setup

1. Change necessary fuse and lock bits on RadIO  
	see: ***Fuse and Lock Bits***
2. Flash the bootloader to RadIO  
	see: ***Flashing the Bootloader***
3. Install the python dependencies (so you can run upload.py)  
	see:  ***Python Dependencies***

### Uploading a program to RadIO

1. Compile the program you want to upload to RadIO  
	see: ***Compiling Code***
2. Prepare RadIO for a serial upload  
	see: ***Entering the Bootloader***
3. Run upload.py to perform the upload  
	see: ***Running upload.py***



## Fuse and Lock Bits  

(0 means **programmed** and 1 means **unprogrammed**)

### Mandatory fuse bits

| Fuse Bit | Value | Explanation                                                                        |
|----------|------:|:----------------------------------------------------------------------------------:|
|BOOTRST   |      0| changes reset vector to location specified by BOOTSZ bits                          |
|BOOTSZ1   |      1| one of two bits that determine where the bootloader section begins, and its size   |
|BOOTSZ2   |      1| when BOOTSZ1 and BOOTSZ2 are both 1 the bootloader section is as small as possible |

To change those fuse bits while maintaining the default RadIO fuse bits, set the fuse bytes as follows:

| Fuse Byte | Value |
|-----------|------:|
|HIGH       |   0xDE|
|LOW        |   0xDE|
|EXTENDED   |   0xFF|


### Optional lock bits

Setting the following lock bits will make it impossible to programmatically overwrite the bootloader:

| Lock Bit | Value |
|----------|------:|
|BLB11     |      0|
|BLB12     |      1|

To change this lock bit while maintaining the RadIO defaults, set the lock bit byte to 0xEF



## Flashing the Bootloader

2 options:

- Use AVRDUDE to flash the provided pre-compiled bootloader, *RadIO Bootloader.hex*  
	(recommended)
- Compile *RadIO Bootloader.asm* yourself using AtmelStudio or an equivalent assembler  
	(advanced)



## Python Dependencies

- **python 3.6** or later
- **pyserial**  
install with pip via `pip install pyserial`



## Compiling Code

Code uploaded using the bootloader must be compiled to **binary** (not hex)  
Also make sure your compiler is targeting either ATmega328p or ATmega328pb  

To compile to binary using the avr-gcc toolchain, run the following commands:  

1. `avr-gcc -Wall -g -Os -mmcu=atmega328p -o output.o input.c`  
	(compiles input.c to output.o)  
2. `avr-objcopy -O binary output.o output.bin`  
	(converts output.o into a raw binary, output.bin)



## Entering the Bootloader

1. Connect RadIO and computer using a USB cable
2. Flip the bootloader enable switch on
3. Reset RadIO (by unplugging the USB or pressing the reset button)
4. Ensure that RadIO's bootloader indicator LED is on



## Running upload.py

`python upload.py <file> <port>`

**file** - The name of the compiled binary file to upload to RadIO  
**port** - (Optional in Windows) The serial port that RadIO is plugged in to

If the program is uploaded successfully the bootloader indicator LED will turn off and the uploaded program will begin