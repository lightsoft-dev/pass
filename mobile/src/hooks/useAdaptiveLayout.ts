import { useWindowDimensions } from "react-native";

const REGULAR_WIDTH = 820;
const WIDE_WIDTH = 1_080;

export function useAdaptiveLayout() {
  const { width, height } = useWindowDimensions();

  return {
    width,
    height,
    isRegular: width >= REGULAR_WIDTH,
    isWide: width >= WIDE_WIDTH,
  };
}
