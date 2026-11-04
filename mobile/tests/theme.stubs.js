// Stand-ins for what theme.ts needs from React Native at run time.
module.exports = {
  __esModule: true,
  default: { getItem: async () => null, setItem: async () => {} },
  useState: value => [value, () => {}],
  useEffect: () => {},
};
