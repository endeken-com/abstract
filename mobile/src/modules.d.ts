declare module 'react-native-zeroconf' {
  export default class Zeroconf {
    on(event: string, callback: (...args: any[]) => void): void;
    scan(type: string, protocol: string, domain: string): void;
    stop(): void;
  }
}
