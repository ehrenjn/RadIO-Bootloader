#CHANGE THIS SO YOU ACTUALLY GET TO CHOOSE THE SERIAL PORT
#MAKE SURE YOU ACTUALLY KNOW HOW THE PARITY STUFF WORKS 
    #rn I'm assuming the parity of a port is used for sending and receiving
#MAKE YOUR SLEEP AS SHORT AS POSSIBLE

import serial
import sys
import os
import time

BAUD_RATE = 38400



class Word:
    '''represents 16 + 2 bits of data to be sent to the bootloader'''

    def __init__(self, data, word_num):
        self._data = data
        self._word_num = word_num

    def get_bytes(self):
        word_start = self._word_num * 2
        for byte_num in range(2):
            index = word_start + byte_num
            if index >= len(self._data): #index is not in data
                yield b'\x00', serial.PARITY_MARK #PARITY_MARK = 1
            else: #index is in data
                byte = self._data[index: index + 1] #slice to get a bytes object instead of an int
                yield byte, serial.PARITY_SPACE #PARITY_SPACE = 0
    
    def location(self):
        '''
        returns how many bytes into self._data this word is located
        as well as the length of the data itself
        '''
        return self._word_num * 2, len(self._data)


def invalid_write():
    print("ERROR: the bootloader attempted to write to a memory location occupied by itself (are you uploading a program > 32256 bytes?)")
    return False


BYTE_ACTIONS = {
    b'w': lambda: True, #next word request
    b'd': lambda: False, #disconnect request
    b'o': invalid_write #invalid write error
}


ERROR_BYTE_MAX = bytes([31])

def is_usart_error_byte(byte):
    return byte <= ERROR_BYTE_MAX

def bit_n(byte, n):
    return (byte & (1 << n)) != 0

def parse_usart_error(error_byte):
    if bit_n(error_byte, 3): #data overrun
        print("ERROR: USART Data OverRun: the bootloader received a new byte while the USART buffer was already full")
    if bit_n(error_byte, 4): #frame error
        print("ERROR: USART Frame Error: the bootloader received one or more invalid start/stop bits")
    return False


LOAD_BAR_LENGTH = 30
RESTART_LINE = "\x1b[F"

def print_stats(word):
    byte_num, total_bytes = word.location()
    num_blocks = round(byte_num/total_bytes * LOAD_BAR_LENGTH)
    loading_bar = "#"*num_blocks + " "*(LOAD_BAR_LENGTH - num_blocks) 
    print(f"{RESTART_LINE}[{loading_bar}] {byte_num}/{total_bytes} bytes uploaded")


def gen_words(data_bytes):
    word_num = 0
    while True:
        yield Word(data_bytes, word_num)
        word_num += 1


def send_word(port, word):
    for byte, parity in word.get_bytes():
        if parity != port.parity: #don't want to set port.parity every time because it's a setter that execs a fair amount of stuff
            time.sleep(0.1) #HAVE TO WAIT A BIT FOR PREVIOUS WRITE TO FINISH BEFORE CHANGING THE PARITY AGAIN (TERRIBLE RACE CONDITION IN PYSERIAL) (if I change the parity right after writing then it'll use that parity instead of the parity set before writing)
            port.parity = parity
        port.write(byte)

def open_port():
    return serial.Serial(
        'COM3', 
        BAUD_RATE, 
        parity = serial.PARITY_SPACE, #USING PARITY AS 9TH BIT (PARITY_SPACE means 0)
        stopbits = serial.STOPBITS_TWO
    )

def windows_start_ansi():
    if sys.platform.startswith('win'): #HAVE TO CLS BEFORE DOING ANY ANSI CONTROL STUFF IN WINDOWS FOR SOME UNGODLY REASON
        os.system('cls')

def upload(data_words):
    windows_start_ansi()
    port = open_port()
    print("uploading...\n")
    for word in data_words:
        send_word(port, word)
        new_byte = port.read(1)
        print_stats(word)
        if is_usart_error_byte(new_byte):
            still_looping = parse_usart_error(new_byte)
        else:
            still_looping = BYTE_ACTIONS[new_byte]()
        if not still_looping:
            break
    print("done")
    port.close()



if __name__ == "__main__":
    if len(sys.argv) >= 2:
        data_file = sys.argv[1]
        try:
            with open(data_file, 'rb') as data:
                word_generator = gen_words(data.read())
        except FileNotFoundError:
            print(f"ERROR: can't read provided file ({data_file})")
        else:
            upload(word_generator)
    else:
        print("ERROR: please provide a program file to upload")